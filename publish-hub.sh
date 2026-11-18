#!/usr/bin/env bash
# publish-hub.sh — Fedora-style binary pool publisher for openOODA/install.
#
#   bash publish-hub.sh [pkg ...]
#
# With no arguments, publishes every canonical package in
# $OODA_POLYROOT/openOODA/catalog/groups.oot (@all = 70 packages across
# openOODA-core, openOODA-system, and openOODA-apps). Named arguments
# publish only those packages. For each package the script locates the
# repo under $OODA_POLYROOT/openOODA-*/, builds it with `make build` when no
# binary is present, stages it as <name>-linux-x86_64 (liboodar.a keeps
# its name; liboodar-*.a slices and optional ooda-runtime-linux-x86_64 also stage
# when built), regenerates the single master SHA256SUMS (+ SHA256SUMS.sig
# when a minisign key is available), copies SHA256SUMS into the catalog
# repo, and uploads everything in place to the single latest GitHub
# Release on openOODA/install. Legacy per-file .sha256 sidecars and
# retired binary assets are deleted; older releases are removed so
# exactly one active Release remains.
#
# Env:
#   OO_PROJECTS_ROOT  default $HOME/openOODA-src
#   OPENOODA_HOME     default $HOME/.openooda (fallback for OODA_OODAR_ROOT/cards)
#   OODA_FS_READDIR   optional sandbox read roots passed to ooda-flasher
#   OODA_FS_WRITEDIR  optional sandbox write roots passed to ooda-flasher
#   OO_MINISIGN_KEY   path to minisign secret for SHA256SUMS.sig
#   OO_HUB_RELEASE    release tag on openOODA/install (default: hub)
#   OO_DRY_RUN=1      stage + print, skip gh upload/delete

set -euo pipefail

ROOT="${OO_PROJECTS_ROOT:-${OODA_POLYROOT:-$HOME/openOODA-src}}"
CATALOG="$ROOT/openOODA/catalog"
GROUPS_FILE="$CATALOG/groups.oot"
ORG_DIRS=(openOODA-core openOODA-system openOODA-apps)
RELEASE_REPO="openOODA/install"
RELEASE_TAG="${OO_HUB_RELEASE:-hub}"
DRY_RUN="${OO_DRY_RUN:-0}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/openooda-hub.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }

# --- canonical package list -------------------------------------------------

# groups.oot line parser: `@name = tok tok ...`; @-tokens expand transitively.
load_groups() {
  [[ -f "$GROUPS_FILE" ]] || die "groups file missing: $GROUPS_FILE"
  declare -gA GDEF=()
  local line g rest
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*@([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    GDEF["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  done < "$GROUPS_FILE"
  [[ ${#GDEF[@]} -gt 0 ]] || die "no @group definitions parsed from $GROUPS_FILE"
}

expand_group() {  # $1 = group name without @; prints deduped members
  local want="$1" out="" seen=" "
  local -a queue=("$want")
  while ((${#queue[@]})); do
    local g="${queue[0]}"; queue=("${queue[@]:1}")
    [[ "$seen" == *" $g "* ]] && continue
    seen="$seen$g "
    [[ -n "${GDEF[$g]:-}" ]] || die "unknown group @$g"
    local tok
    for tok in ${GDEF[$g]}; do
      if [[ "$tok" == @* ]]; then queue+=("${tok#@}"); else out="$out $tok"; fi
    done
  done
  printf '%s\n' $out | awk 'NF && !seen[$0]++'
}

canonical_pkgs() {
  if (($#)); then
    local a need_groups=0
    for a in "$@"; do [[ "$a" == @* ]] && need_groups=1; done
    [[ $need_groups == 1 ]] && load_groups
    for a in "$@"; do
      if [[ "$a" == @* ]]; then expand_group "${a#@}"; else printf '%s\n' "$a"; fi
    done | awk 'NF && !seen[$0]++'
    return
  fi
  load_groups
  expand_group all
}

# --- repo lookup --------------------------------------------------------------

find_repo() {  # $1 = package name → prints repo dir or nothing
  local org d
  for org in "${ORG_DIRS[@]}"; do
    d="$ROOT/$org/$1"
    [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

# Binary basenames a repo may produce, in preference order. ooda-runtime's
# product is the liboodar.a archive; the canonical names are tried first and
# the retired oo* spellings kept as fallbacks for stale build trees.
bin_candidates() {
  case "$1" in
    ooda-compiler)   printf 'ooda-compiler\noodac\n';;
    ooda-runtime)    printf 'liboodar.a\n';;
    ooda-language)   printf 'ooda-language\nooda-lsp\noolsp\n';;
    ooda-bridge)     printf 'ooda-bridge\nooda-mcp\noomcp\n';;
    ooda-filesystem) printf 'ooda-filesystem\nooda-filesystem-linux-x86_64\noofs\noofs-linux-x86_64\noocp\noocp-linux-x86_64\n';;
    ooda-hardware)   printf 'ooda-hardware\nooda-hardware-linux-x86_64\noohw\noohw-linux-x86_64\noohwinfo\noohwinfo-linux-x86_64\n';;
    ooda-disk)       printf 'ooda-disk\nooda-disk-linux-x86_64\nooperm\nooperm-linux-x86_64\noochmod\noochmod-linux-x86_64\n';;
    *)               printf '%s\n%s-linux-x86_64\n' "$1" "$1";;
  esac
}

locate_binary() {  # $1 = repo dir, $2 = package name → prints path or nothing
  local repo="$1" pkg="$2" cand rel
  while IFS= read -r cand; do
    for rel in "dist/$cand" "bin/$cand" "core/lib/$cand" "scripts/lib/$cand" "$cand"; do
      [[ -f "$repo/$rel" && -s "$repo/$rel" ]] && { printf '%s\n' "$repo/$rel"; return 0; }
    done
  done < <(bin_candidates "$pkg")
  return 1
}

ensure_binary() {  # $1 = package name → prints path to built binary
  local pkg="$1" repo bin
  repo="$(find_repo "$pkg")" || die "no repo for package $pkg under $ROOT/openOODA-*"
  bin="$(locate_binary "$repo" "$pkg" || true)"
  if [[ -z "$bin" && -f "$repo/Makefile" ]]; then
    say "building $pkg ($(basename "$repo"))" >&2
    ( cd "$repo" && make build >/dev/null 2>&1 ) || \
      ( cd "$repo" && make >/dev/null 2>&1 ) || true
    bin="$(locate_binary "$repo" "$pkg" || true)"
  fi
  [[ -n "$bin" ]] || die "no binary for $pkg in $repo (make build produced nothing locatable)"
  printf '%s\n' "$bin"
}

# --- staging + checksums -------------------------------------------------------

stage_pkg() {  # $1 = package name
  local pkg="$1" bin asset
  if [[ "$pkg" == "ooda-standard" ]]; then
    local repo
    repo="$(find_repo ooda-standard)" || die "no repo for ooda-standard"
    asset="ooda-standard-linux-x86_64.tar.gz"
    ( cd "$repo" && tar --exclude='.git' --exclude='.ooda-cache' --exclude='bin' --exclude='dist' -czf "$STAGE/$asset" . )
    chmod 0644 "$STAGE/$asset"
    say "staged $asset <- $repo (source archive)"
    return 0
  fi
  bin="$(ensure_binary "$pkg")"
  if [[ "$pkg" == "ooda-runtime" ]]; then asset="liboodar.a"; else asset="${pkg}-linux-x86_64"; fi
  cp -f "$bin" "$STAGE/$asset"
  chmod 0644 "$STAGE/$asset"
  say "staged $asset <- $bin"
  # Sibling persona binaries (bin/<pkg>-<persona>) colocate with the main
  # asset: multi-binary tools exec their siblings at runtime (ooda-container
  # forwards build/infer/sched under ProcessCap). Test binaries never match
  # this glob (test_* stem), and repos without siblings stage nothing extra.
  local repo sib sibbase
  repo="$(find_repo "$pkg")" || return 0
  if [[ "$pkg" == "ooda-runtime" ]]; then
    local rdir ar arbase rtbin
    for rdir in "$repo/core/lib" "$repo/dist" "$repo/bin" "$repo/scripts/lib"; do
      for ar in "$rdir"/liboodar-*.a; do
        [[ -f "$ar" && -s "$ar" ]] || continue
        arbase="$(basename "$ar")"
        [[ -f "$STAGE/$arbase" ]] && continue
        cp -f "$ar" "$STAGE/$arbase"
        chmod 0644 "$STAGE/$arbase"
        say "staged $arbase <- $ar"
      done
    done
    for rtbin in "$repo/dist/ooda-runtime" "$repo/bin/ooda-runtime"; do
      if [[ -f "$rtbin" && -s "$rtbin" ]]; then
        cp -f "$rtbin" "$STAGE/ooda-runtime-linux-x86_64"
        chmod 0644 "$STAGE/ooda-runtime-linux-x86_64"
        say "staged ooda-runtime-linux-x86_64 <- $rtbin"
        break
      fi
    done
  fi
  for sib in "$repo"/bin/"$pkg"-*; do
    [[ -f "$sib" && -x "$sib" ]] || continue
    sibbase="$(basename "$sib")"
    cp -f "$sib" "$STAGE/${sibbase}-linux-x86_64"
    chmod 0644 "$STAGE/${sibbase}-linux-x86_64"
    say "staged ${sibbase}-linux-x86_64 <- $sib"
  done
}

stage_images() {
  # 1. Stage ooda-os-x86_64.iso (bootable UEFI/BIOS ISO9660 image packed by ooda-flasher)
  local iso_dir="$STAGE/iso-root"
  mkdir -p "$iso_dir/EFI/BOOT" "$iso_dir/boot" "$iso_dir/bin"
  [[ -f "$STAGE/ooda-boot-linux-x86_64" ]] && cp -f "$STAGE/ooda-boot-linux-x86_64" "$iso_dir/EFI/BOOT/BOOTX64.EFI"
  [[ -f "$STAGE/ooda-boot-linux-x86_64" ]] && cp -f "$STAGE/ooda-boot-linux-x86_64" "$iso_dir/boot/eltorito.img"
  [[ -f "$STAGE/ooda-boot-linux-x86_64" ]] && cp -f "$STAGE/ooda-boot-linux-x86_64" "$iso_dir/boot/efi.img"
  [[ -f "$STAGE/ooda-kernel-linux-x86_64" ]] && cp -f "$STAGE/ooda-kernel-linux-x86_64" "$iso_dir/boot/ooda-kernel"
  [[ -f "$STAGE/ooda-start-linux-x86_64" ]] && cp -f "$STAGE/ooda-start-linux-x86_64" "$iso_dir/bin/ooda-start"
  [[ -f "$STAGE/ooda-shell-linux-x86_64" ]] && cp -f "$STAGE/ooda-shell-linux-x86_64" "$iso_dir/bin/ooda-shell"
  local flasher="$ROOT/openOODA-apps/ooda-flasher/bin/ooda-flasher"
  if [[ ! -x "$flasher" && -f "$ROOT/openOODA-apps/ooda-flasher/Makefile" ]]; then
    ( cd "$ROOT/openOODA-apps/ooda-flasher" && make build >/dev/null 2>&1 ) || true
  fi
  if [[ -x "$flasher" ]]; then
    OODA_FS_READDIR="${OODA_FS_READDIR:-$ROOT:${OPENOODA_HOME:-$HOME/.openooda}:/tmp:/proc:/sys:/usr:/etc:/lib:/lib64}:$STAGE" \
    OODA_FS_WRITEDIR="${OODA_FS_WRITEDIR:+$OODA_FS_WRITEDIR:}$STAGE:/tmp" \
      "$flasher" pack-iso "$iso_dir" -o "$STAGE/ooda-os-x86_64.iso" >/dev/null 2>&1 || true
    rm -f "$STAGE/ooda-os-x86_64.iso.manifest"
  fi
  rm -rf "$iso_dir"
  if [[ -s "$STAGE/ooda-os-x86_64.iso" ]]; then
    chmod 0644 "$STAGE/ooda-os-x86_64.iso"
    say "staged ooda-os-x86_64.iso (bootable ISO9660 image)"
  fi

  # 2. Stage ooda-buildbox-x86_64.tar.gz (hermetic L0 buildbox container rootfs)
  local bb_dir="$STAGE/buildbox-root"
  mkdir -p "$bb_dir/bin" "$bb_dir/lib" "$bb_dir/ooda-standard"
  for c in ooda ooda-compiler ooda-package ooda-language ooda-bridge ooda-verify ooda-container ooda-shell; do
    [[ -f "$STAGE/${c}-linux-x86_64" ]] && cp -f "$STAGE/${c}-linux-x86_64" "$bb_dir/bin/$c" && chmod 0755 "$bb_dir/bin/$c"
  done
  [[ -f "$STAGE/liboodar.a" ]] && cp -f "$STAGE/liboodar.a" "$bb_dir/lib/liboodar.a"
  [[ -f "$ROOT/openOODA/openOODA/AGENTS.md" ]] && cp -f "$ROOT/openOODA/openOODA/AGENTS.md" "$bb_dir/AGENTS.md"
  ( cd "$bb_dir" && tar -czf "$STAGE/ooda-buildbox-x86_64.tar.gz" . )
  rm -rf "$bb_dir"
  chmod 0644 "$STAGE/ooda-buildbox-x86_64.tar.gz"
  say "staged ooda-buildbox-x86_64.tar.gz (hermetic buildbox container bundle)"

  # 3. Stage openooda root binary + codex bundle (AGENTS.md + cards/)
  if [[ -d "$ROOT/openOODA/openOODA" ]]; then
    [[ -x "$ROOT/openOODA/openOODA/bin/openooda" ]] || ( cd "$ROOT/openOODA/openOODA" && make build >/dev/null 2>&1 ) || true
    if [[ -s "$ROOT/openOODA/openOODA/bin/openooda" ]]; then
      cp -f "$ROOT/openOODA/openOODA/bin/openooda" "$STAGE/openooda-linux-x86_64"
      chmod 0644 "$STAGE/openooda-linux-x86_64"
      say "staged openooda-linux-x86_64 <- $ROOT/openOODA/openOODA/bin/openooda"
    fi
    ( cd "$ROOT/openOODA/openOODA" && tar -czf "$STAGE/openooda-codex-linux-x86_64.tar.gz" AGENTS.md cards )
    chmod 0644 "$STAGE/openooda-codex-linux-x86_64.tar.gz"
    say "staged openooda-codex-linux-x86_64.tar.gz <- $ROOT/openOODA/openOODA (AGENTS.md + cards)"
  fi
  # 4. Stage canonical capability table unconditionally so subset publishes keep hub complete.
  local cap_src=""
  if [[ -s "$ROOT/openOODA-core/ooda-runtime/core/sec/cap/cap_table.oot" ]]; then
    cap_src="$ROOT/openOODA-core/ooda-runtime/core/sec/cap/cap_table.oot"
  elif [[ -s "$ROOT/ooda-runtime/core/sec/cap/cap_table.oot" ]]; then
    cap_src="$ROOT/ooda-runtime/core/sec/cap/cap_table.oot"
  elif [[ -s "${OPENOODA_HOME:-$HOME/.openooda}/cards/cap_table.oot" ]]; then
    cap_src="${OPENOODA_HOME:-$HOME/.openooda}/cards/cap_table.oot"
  fi
  if [[ -n "$cap_src" ]]; then
    cp -f "$cap_src" "$STAGE/cap_table.oot"
    chmod 0644 "$STAGE/cap_table.oot"
    say "staged cap_table.oot <- $cap_src"
  else
    warn "cap_table.oot not found under $ROOT; keeping existing hub asset"
  fi
}

is_canonical_asset() {
  case "$1" in
    SHA256SUMS|SHA256SUMS.sig|cap_table.oot|liboodar.a|liboodar-*.a|\
    ooda-standard-linux-x86_64.tar.gz|openooda-codex-linux-x86_64.tar.gz|\
    ooda-os-x86_64.iso|ooda-buildbox-x86_64.tar.gz|ooda-linux-x86_64|\
    openooda-linux-x86_64)
      return 0;;
    ooda-lsp-*|ooda-mcp-*)
      return 1;;
    ooda-*-linux-x86_64)
      return 0;;
    *)
      return 1;;
  esac
}

gen_sums() {
  ( cd "$STAGE" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%f\n' \
      | LC_ALL=C sort | xargs sha256sum > SHA256SUMS.new )
  [[ -s "$STAGE/SHA256SUMS.new" ]] || die "SHA256SUMS generation produced nothing"
  # Merge with live canonical hub sums so subset publishes keep un-staged canonical
  # assets covered while retired pre-rename oo* entries are stripped out.
  local prev="$STAGE/.hub_SHA256SUMS.prev" live="$STAGE/.hub_assets.live" live_canon="$STAGE/.hub_assets.canon"
  if [[ "$DRY_RUN" != "1" ]] && command -v gh >/dev/null 2>&1 && \
      gh release download "$RELEASE_TAG" -R "$RELEASE_REPO" --pattern 'SHA256SUMS' \
        --clobber -O "$prev" >/dev/null 2>&1 && [[ -s "$prev" ]] && \
      gh release view "$RELEASE_TAG" -R "$RELEASE_REPO" --json assets \
        -q '.assets[].name' >"$live" 2>/dev/null && [[ -s "$live" ]]; then
    : > "$live_canon"
    while IFS= read -r asset_name; do
      [[ -n "$asset_name" ]] && is_canonical_asset "$asset_name" && printf '%s\n' "$asset_name" >> "$live_canon"
    done < "$live"
    awk 'NR==FNR { fresh[$2]=1; next } !($2 in fresh)' \
      "$STAGE/SHA256SUMS.new" "$prev" | \
      awk 'NR==FNR { live[$1]=1; next } ($2 in live)' "$live_canon" - | \
      cat - "$STAGE/SHA256SUMS.new" | LC_ALL=C sort -k2 > "$STAGE/SHA256SUMS"
    say "merged $(wc -l <"$STAGE/SHA256SUMS") master sums entries with canonical hub state"
  else
    mv -f "$STAGE/SHA256SUMS.new" "$STAGE/SHA256SUMS"
    say "shipping $(wc -l <"$STAGE/SHA256SUMS") master sums entries from staged release"
  fi
  rm -f "$STAGE/SHA256SUMS.new" "$prev" "$live" "$live_canon"
  if [[ -n "${OO_MINISIGN_KEY:-}" && -f "${OO_MINISIGN_KEY}" ]] && command -v minisign >/dev/null 2>&1; then
    ( cd "$STAGE" && minisign -S -s "$OO_MINISIGN_KEY" -m SHA256SUMS -x SHA256SUMS.sig ) && \
      ok "signed SHA256SUMS -> SHA256SUMS.sig" || warn "minisign failed; shipping unsigned sums"
  else
    warn "no OO_MINISIGN_KEY/minisign; SHA256SUMS.sig not generated"
  fi
  cp -f "$STAGE/SHA256SUMS" "$CATALOG/SHA256SUMS"
  ok "master SHA256SUMS -> catalog/SHA256SUMS"
}

# --- release hygiene -------------------------------------------------------------

ensure_single_release() {
  local tags
  tags="$(gh release list -R "$RELEASE_REPO" --limit 100 --json tagName -q '.[].tagName' 2>/dev/null || true)"
  if ! printf '%s\n' "$tags" | grep -qx "$RELEASE_TAG"; then
    gh release create "$RELEASE_TAG" -R "$RELEASE_REPO" \
      --title "openOODA binary hub" --notes "Single binary pool. SHA256SUMS is the master checksum; install.sh verifies against it." || \
      die "cannot create release $RELEASE_TAG on $RELEASE_REPO"
    ok "created release $RELEASE_TAG"
  fi
  local t
  while IFS= read -r t; do
    [[ -n "$t" && "$t" != "$RELEASE_TAG" ]] || continue
    gh release delete "$t" -R "$RELEASE_REPO" -y >/dev/null 2>&1 && \
      say "deleted older release $t"
  done <<< "$tags"
}

prune_assets() {
  # Allowlist hygiene: the pool keeps exactly SHA256SUMS*, liboodar.a, and
  # <pkg>-linux-x86_64 binaries. Everything else — legacy per-file .sha256
  # sidecars, retired bare stems (cli, tui, ooarchitect, oodo, and the
  # pre-rename opm/ooda-lsp/ooda-mcp spellings) — is deleted so the master
  # SHA256SUMS stays the only checksum channel.
  local names n
  names="$(gh release view "$RELEASE_TAG" -R "$RELEASE_REPO" --json assets -q '.assets[].name' 2>/dev/null || true)"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    case "$n" in
      ooagent-hud-*|ooquota-*|ootui-*|oocli-*|oocap-*|oodac-*|oodar-*|oopm-*|\
      oolsp-*|oomcp-*|oohat-*|oostd-*|oofs-*|oohw-*|ooperm-*|ooboot-*|\
      ookernel-*|ooinit-*|oosh-*|oocontainer-*|ooflash-*|opm-*|ooda-lsp-*|\
      ooda-mcp-*)
        say "deleting retired package asset $n"
        [[ "$DRY_RUN" == "1" ]] || \
          gh release delete-asset "$RELEASE_TAG" "$n" -R "$RELEASE_REPO" -y >/dev/null 2>&1 || true
        ;;
      *)
        if is_canonical_asset "$n"; then
          :
        else
          say "deleting legacy asset $n"
          [[ "$DRY_RUN" == "1" ]] || \
            gh release delete-asset "$RELEASE_TAG" "$n" -R "$RELEASE_REPO" -y >/dev/null 2>&1 || true
        fi
        ;;
    esac
  done <<< "$names"
}

upload_all() {
  local f
  for f in "$STAGE"/*; do
    [[ -f "$f" ]] || continue
    say "upload $(basename "$f")"
    [[ "$DRY_RUN" == "1" ]] || \
      gh release upload "$RELEASE_TAG" "$f" -R "$RELEASE_REPO" --clobber >/dev/null
  done
}

# --- main -------------------------------------------------------------------------

main() {
  say "openOODA hub publish -> $RELEASE_REPO@$RELEASE_TAG"
  local pkgs
  pkgs="$(canonical_pkgs "$@")"
  [[ -n "$pkgs" ]] || die "empty package selection"
  local n=0 name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    stage_pkg "$name"; n=$((n+1))
  done <<< "$pkgs"
  stage_images
  ok "staged $n package assets + ISO & buildbox images in $STAGE"
  gen_sums
  if [[ "$DRY_RUN" == "1" ]]; then
    say "[dry-run] would ensure single release, prune legacy assets, upload $(ls "$STAGE" | wc -l) files"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || die "gh CLI required"
  ensure_single_release
  prune_assets
  upload_all
  local asset_count
  asset_count="$(gh release view "$RELEASE_TAG" -R "$RELEASE_REPO" --json assets -q '.assets | length')"
  say "release now carries $asset_count assets"
  ok "hub publish complete"
}

main "$@"
