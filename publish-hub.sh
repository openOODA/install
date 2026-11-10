#!/usr/bin/env bash
# publish-hub.sh — Fedora-style binary pool publisher for openOODA/install.
#
#   bash publish-hub.sh [pkg ...]
#
# With no arguments, publishes every canonical package in
# /Projects/openOODA/catalog/groups.oot (@all expansion). Named arguments
# publish only those packages. For each package the script locates the
# repo under /Projects/openOODA-*/, builds it with `make build` when no
# binary is present, stages it as <name>-linux-x86_64 (liboodar.a keeps
# its name), regenerates the single master SHA256SUMS (+ SHA256SUMS.sig
# when a minisign key is available), copies SHA256SUMS into the catalog
# repo, and uploads everything in place to the single latest GitHub
# Release on openOODA/install. Legacy per-file .sha256 sidecars and
# retired binary assets are deleted; older releases are removed so
# exactly one active Release remains.
#
# Env:
#   OO_PROJECTS_ROOT  default /Projects
#   OO_MINISIGN_KEY   path to minisign secret for SHA256SUMS.sig
#   OO_HUB_RELEASE    release tag on openOODA/install (default: hub)
#   OO_DRY_RUN=1      stage + print, skip gh upload/delete

set -euo pipefail

ROOT="${OO_PROJECTS_ROOT:-/Projects}"
CATALOG="$ROOT/openOODA/catalog"
GROUPS_FILE="$CATALOG/groups.oot"
ORG_DIRS=(openOODA-core openOODA-kernel openOODA-OS openOODA-tools \
          openOODA-DE openOODA-apps openOODA-cloud openOODA-agents)
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

# Binary basenames a repo may produce, in preference order. oolsp's product
# binary is ooda-lsp; oodar's product is the liboodar.a archive.
bin_candidates() {
  case "$1" in
    oodac)  printf 'oodac.real\noodac\n';;
    oodar)  printf 'liboodar.a\n';;
    oolsp)  printf 'oolsp\nooda-lsp\n';;
    oofs)   printf 'oofs\noofs-linux-x86_64\noocp\noocp-linux-x86_64\n';;
    oohw)   printf 'oohw\noohw-linux-x86_64\noohwinfo\noohwinfo-linux-x86_64\n';;
    ooperm) printf 'ooperm\nooperm-linux-x86_64\noochmod\noochmod-linux-x86_64\n';;
    *)      printf '%s\n%s-linux-x86_64\n' "$1" "$1";;
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
    say "building $pkg ($(basename "$repo"))"
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
  if [[ "$pkg" == "oostd" ]]; then
    local repo
    repo="$(find_repo oostd)" || die "no repo for oostd"
    asset="oostd-linux-x86_64.tar.gz"
    ( cd "$repo" && tar --exclude='.git' --exclude='.ooda-cache' --exclude='bin' --exclude='dist' -czf "$STAGE/$asset" . )
    chmod 0644 "$STAGE/$asset"
    say "staged $asset <- $repo (source archive)"
    return 0
  fi
  bin="$(ensure_binary "$pkg")"
  if [[ "$pkg" == "oodar" ]]; then asset="liboodar.a"; else asset="${pkg}-linux-x86_64"; fi
  cp -f "$bin" "$STAGE/$asset"
  chmod 0644 "$STAGE/$asset"
  say "staged $asset <- $bin"
}

stage_images() {
  # 1. Stage ooda-os-x86_64.iso (bootable UEFI/BIOS ISO9660 image packed by ooflash)
  local iso_dir="$STAGE/iso-root"
  mkdir -p "$iso_dir/EFI/BOOT" "$iso_dir/boot" "$iso_dir/bin"
  [[ -f "$STAGE/ooboot-linux-x86_64" ]] && cp -f "$STAGE/ooboot-linux-x86_64" "$iso_dir/EFI/BOOT/BOOTX64.EFI"
  [[ -f "$STAGE/ooboot-linux-x86_64" ]] && cp -f "$STAGE/ooboot-linux-x86_64" "$iso_dir/boot/eltorito.img"
  [[ -f "$STAGE/ooboot-linux-x86_64" ]] && cp -f "$STAGE/ooboot-linux-x86_64" "$iso_dir/boot/efi.img"
  [[ -f "$STAGE/ookernel-linux-x86_64" ]] && cp -f "$STAGE/ookernel-linux-x86_64" "$iso_dir/boot/ookernel"
  [[ -f "$STAGE/ooinit-linux-x86_64" ]] && cp -f "$STAGE/ooinit-linux-x86_64" "$iso_dir/bin/ooinit"
  [[ -f "$STAGE/oosh-linux-x86_64" ]] && cp -f "$STAGE/oosh-linux-x86_64" "$iso_dir/bin/oosh"
  if [[ -x "$ROOT/openOODA-apps/ooflash/bin/ooflash" ]]; then
    "$ROOT/openOODA-apps/ooflash/bin/ooflash" pack-iso "$iso_dir" -o "$STAGE/ooda-os-x86_64.iso" >/dev/null 2>&1 || true
    rm -f "$STAGE/ooda-os-x86_64.iso.manifest"
  fi
  rm -rf "$iso_dir"
  if [[ -s "$STAGE/ooda-os-x86_64.iso" ]]; then
    chmod 0644 "$STAGE/ooda-os-x86_64.iso"
    say "staged ooda-os-x86_64.iso (bootable ISO9660 image)"
  fi

  # 2. Stage ooda-buildbox-x86_64.tar.gz (hermetic L0 buildbox container rootfs)
  local bb_dir="$STAGE/buildbox-root"
  mkdir -p "$bb_dir/bin" "$bb_dir/lib" "$bb_dir/oostd"
  for c in ooda oodac oopm oolsp oomcp oocontainer oohat oosh; do
    [[ -f "$STAGE/${c}-linux-x86_64" ]] && cp -f "$STAGE/${c}-linux-x86_64" "$bb_dir/bin/$c" && chmod 0755 "$bb_dir/bin/$c"
  done
  [[ -f "$STAGE/liboodar.a" ]] && cp -f "$STAGE/liboodar.a" "$bb_dir/lib/liboodar.a"
  [[ -f "$ROOT/openOODA/openOODA/AGENTS.md" ]] && cp -f "$ROOT/openOODA/openOODA/AGENTS.md" "$bb_dir/AGENTS.md"
  ( cd "$bb_dir" && tar -czf "$STAGE/ooda-buildbox-x86_64.tar.gz" . )
  rm -rf "$bb_dir"
  chmod 0644 "$STAGE/ooda-buildbox-x86_64.tar.gz"
  say "staged ooda-buildbox-x86_64.tar.gz (hermetic buildbox container bundle)"
}

gen_sums() {
  ( cd "$STAGE" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%f\n' \
      | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
  [[ -s "$STAGE/SHA256SUMS" ]] || die "SHA256SUMS generation produced nothing"
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
      ooagent-hud-*|ooquota-*|ootui-*|oocli-*|oocap-*)
        say "deleting retired package asset $n"
        [[ "$DRY_RUN" == "1" ]] || \
          gh release delete-asset "$RELEASE_TAG" "$n" -R "$RELEASE_REPO" -y >/dev/null 2>&1 || true
        ;;
      SHA256SUMS|SHA256SUMS.sig|liboodar.a|oostd-linux-x86_64.tar.gz|ooda-os-x86_64.iso|ooda-buildbox-x86_64.tar.gz|*-linux-x86_64) ;;
      *)
        say "deleting legacy asset $n"
        [[ "$DRY_RUN" == "1" ]] || \
          gh release delete-asset "$RELEASE_TAG" "$n" -R "$RELEASE_REPO" -y >/dev/null 2>&1 || true
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
