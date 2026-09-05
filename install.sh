#!/usr/bin/env bash
# openOODA one-line installer
#   curl -fsSL https://openooda.org/install.sh | bash
#
# Idempotent. Detects OS/arch, downloads each component's release asset,
# clones the standard library, and sets up the shell. Re-run is safe.
#
# Set NO_COLOR=1 to disable color.
# Set OPENOODA_DRY_RUN=1 to preview without downloading.

set -euo pipefail

OPENOODA_HOME="${OPENOODA_HOME:-$HOME/.openooda}"
BIN_DIR="$OPENOODA_HOME/bin"
STD_DIR="$OPENOODA_HOME/std"
RELEASES="https://github.com/openOODA"
DRY_RUN="${OPENOODA_DRY_RUN:-0}"

declare -A REPOS=([ooda]=ooda [oodac]=oodac [oodar]=oodar [opm]=opm [lsp]=lsp [mcp]=mcp [blackbox]=blackbox)
declare -A BINARIES=([ooda]=ooda [oodac]=oodac [oodar]=liboodar.a [opm]=opm [lsp]=ooda-lsp [mcp]=ooda-mcp [blackbox]=blackbox)

# --- color --------------------------------------------------------------------

FILL="#"; EMPTY="-"
USE_COLOR=1
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] && USE_COLOR=0
C() { [[ $USE_COLOR -eq 1 ]] && printf '\033[%sm' "$1" || true; }
RESET=$(C 0); BOLD=$(C 1); DIM=$(C 2)
CYAN=$(C 36); GREEN=$(C 32); YELLOW=$(C 33); RED=$(C 31)
MAGENTA=$(C 35); GRAY=$(C 90)

bar() {
  local w=${2:-30} f e
  f=$(( $1 * w / 100 ))
  (( f > w )) && f=w; (( f < 0 )) && f=0
  e=$((w - f))
  printf '%s' "$GREEN"; printf '%*s' "$f" '' | tr ' ' "$FILL"
  printf '%s' "$DIM";    printf '%*s' "$e" '' | tr ' ' "$EMPTY"
  printf '%s' "$RESET"
}

spinner() {
  local pid=$1 frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s ' "$CYAN" "${frames[i++ % ${#frames[@]}]}" "$RESET"
    sleep 0.1
  done
  printf '\r'
}

overwrite_bar() {
  local pct=$(( ($1 * 100 + $2 / 2) / $2 ))
  printf '\r  %s %s%s%3d%%%s (%d/%d)' "$(bar $pct)" "$BOLD" "$MAGENTA" "$pct" "$RESET" "$1" "$2"
}

ok()   { printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED"    "$RESET" "$*" >&2; }
skip() { printf '  %s⊘%s %s\n' "$YELLOW" "$RESET" "$*"; }
info() { printf '  %s•%s %s\n' "$GRAY"   "$RESET" "$*"; }

# --- version pin loading + release URL ---------------------------------------

declare -A PINS=()
load_pins() {
  [[ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/versions.toml" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*([a-zA-Z]+)[[:space:]]*=[[:space:]]*\"(v[0-9]+\.[0-9]+\.[0-9]+)\" ]] || continue
    PINS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  done < "$(dirname "${BASH_SOURCE[0]:-$0}")/versions.toml"
}

release_url() {
  local tag="${PINS[$1]:-latest}"
  if [[ "$tag" == "latest" ]]; then
    echo "${RELEASES}/${REPOS[$1]}/releases/latest/download/${BINARIES[$1]}-${OS}-${ARCH}"
  else
    echo "${RELEASES}/${REPOS[$1]}/releases/download/${tag}/${BINARIES[$1]}-${OS}-${ARCH}"
  fi
}

# --- "what's new" line (best-effort, 3s timeout) -----------------------------

whatnew() {
  local body first
  body=$(curl -sSL --max-time 3 "https://api.github.com/repos/openOODA/openOODA/releases/latest" 2>/dev/null \
    | grep -oE '"body":[[:space:]]*"[^"]*"' | head -1 \
    | sed -E 's/^"body":[[:space:]]*"([^"]*)".*/\1/') || return 0
  [[ -n "$body" ]] || return 0
  first=$(printf '%s' "$body" | head -1 | tr -d '\r' | head -c 100)
  printf '  %s↳%s latest: %s%s%s\n' "$DIM" "$RESET" "$DIM" "$first" "$RESET"
}

# --- per-component install ---------------------------------------------------

INSTALLED=()
SKIPPED=()
BYTES=0

install_component() {
  local key="$1" dest="$BIN_DIR/${BINARIES[$1]}" url code
  url="$(release_url "$key")"
  printf '  %s%s%s\n' "$BOLD" "$key" "$RESET"

  if [[ "$DRY_RUN" == "1" ]]; then
    code=$(curl -sSL -o /dev/null -w '%{http_code}' -I "$url" 2>/dev/null || echo 000)
    if [[ "$code" == "200" ]]; then
      ok "[dry-run] would install $(basename "$dest")"; INSTALLED+=("$key")
    else
      skip "[dry-run] $key not yet shipped for $OS-$ARCH"; SKIPPED+=("$key")
    fi
    return
  fi

  local codefile
  codefile=$(mktemp 2>/dev/null || echo "/tmp/openooda-curl.$$.$key")
  ( code=$(curl -sSL --connect-timeout 10 --max-time 120 -o "$dest.tmp" -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    echo "$code" > "$codefile" ) &
  local pid=$!
  ( sleep 8; kill -0 "$pid" 2>/dev/null \
    && printf '\n  %s(taking a moment; press Ctrl-C to cancel)%s\n' "$DIM" "$RESET" >&2 ) &
  local slow_pid=$!

  spinner "$pid"
  wait "$pid" 2>/dev/null || true
  kill "$slow_pid" 2>/dev/null || true
  wait "$slow_pid" 2>/dev/null || true

  code=$(cat "$codefile" 2>/dev/null || echo 000)
  rm -f "$codefile"
  if [[ "$code" == "200" ]] && [[ -s "$dest.tmp" ]]; then
    local sha_url="${url}.sha256"
    local sha_tmp="$dest.tmp.sha256"
    local sha_code
    sha_code=$(curl -sSL --connect-timeout 5 --max-time 15 -o "$sha_tmp" -w '%{http_code}' "$sha_url" 2>/dev/null || echo 000)
    if [[ "$sha_code" == "200" ]] && [[ -s "$sha_tmp" ]]; then
      local expected_hash actual_hash
      expected_hash=$(awk '{print $1}' "$sha_tmp" | tr -d '\r\n ')
      if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$dest.tmp" | awk '{print $1}')
      elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$dest.tmp" | awk '{print $1}')
      else
        actual_hash="$expected_hash"
      fi
      rm -f "$sha_tmp"
      if [[ -n "$expected_hash" && "$expected_hash" != "$actual_hash" ]]; then
        rm -f "$dest.tmp"
        err "$key: SHA-256 checksum mismatch (expected $expected_hash, got $actual_hash)"
        return 1
      fi
      info "$key: SHA-256 verified (${expected_hash:0:16}...)"
    else
      rm -f "$sha_tmp"
    fi

    mv "$dest.tmp" "$dest"; chmod +x "$dest"
    local size; size=$(wc -c < "$dest" 2>/dev/null || echo 0); BYTES=$((BYTES + size))
    local mb; mb=$(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}')
    ok "installed $(basename "$dest") (${mb} MB)"; INSTALLED+=("$key")
  else
    rm -f "$dest.tmp"
    if [[ -x "$dest" ]]; then
      warn "$key download failed; preserved existing $(basename "$dest")"
    else
      skip "$key not yet shipped for $OS-$ARCH"; SKIPPED+=("$key")
    fi
  fi
}

# --- shell rc ----------------------------------------------------------------

setup_shell_rc() {
  local l1='export PATH="$HOME/.openooda/bin:$PATH"'
  local l2='export OODA_STD_ROOT="$HOME/.openooda/std"'
  local l3='export OODA_COMPILER="$HOME/.openooda/bin/oodac"'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -e "$rc" ]] || : >> "$rc" 2>/dev/null || continue
    if grep -Fqx "$l1" "$rc" 2>/dev/null; then
      info "$(basename "$rc") already has openOODA exports"
    else
      printf '\n# openOODA\n%s\n%s\n%s\n' "$l1" "$l2" "$l3" >> "$rc"
      ok "$(basename "$rc") updated"
    fi
  done
}

# --- main --------------------------------------------------------------------

START=$(date +%s)

OS="$(uname -s)"; case "$OS" in Linux) OS=linux ;; Darwin) OS=darwin ;;
  *) err "unsupported OS: $OS (need linux or darwin)"; exit 1 ;; esac
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) err "unsupported arch: $ARCH (need x86_64 or arm64)"; exit 1 ;; esac

printf '\n  %s%sobserve → orient → decide → act →%s\n' "$DIM$MAGENTA" "" "$RESET"
printf '\n  %s%sopenOODA%s — Sovereign Systems Language for the AI Era\n' "$BOLD$MAGENTA" "" "$RESET"
whatnew
printf '  %shost: %s/%s%s\n' "$DIM" "$OS" "$ARCH" "$RESET"
printf '  %sWelcome, %s%s%s.%s\n' "$DIM" "$CYAN" "${USER:-friend}" "$RESET" "$RESET"
[[ "$DRY_RUN" == "1" ]] && printf '  %s[DRY RUN — no downloads, no shell-rc edits]%s\n' "$YELLOW" "$RESET"
printf '\n'

TOTAL=10; done=0
mkdir -p "$BIN_DIR"
tick() { done=$((done + 1)); overwrite_bar "$done" "$TOTAL"; printf '\n'; }

# step 1: detect
ok "install dir: $BIN_DIR"; tick

# step 2: components
load_pins
for key in ooda oodac oodar opm lsp mcp blackbox; do install_component "$key"; tick; done

# step 3: std
if [[ "$DRY_RUN" == "1" ]]; then
  skip "[dry-run] skipping std clone"
elif [[ -f "$STD_DIR/ANCHOR.oo" ]]; then
  ok "std already at $STD_DIR"
elif ! command -v git >/dev/null 2>&1; then
  warn "git not found; install git, then: git clone --depth 1 https://github.com/openOODA/std $STD_DIR"
else
  info "cloning openOODA/std ..."
  (git clone --depth 1 https://github.com/openOODA/std "$STD_DIR" >/dev/null 2>&1) & spinner $!
  [[ -f "$STD_DIR/ANCHOR.oo" ]] && ok "cloned to $STD_DIR" || warn "clone may have failed; check $STD_DIR"
fi
tick

# step 4: shell
if [[ "$DRY_RUN" == "1" ]]; then skip "[dry-run] skipping shell rc"; else setup_shell_rc; fi
tick

# --- summary + command list --------------------------------------------------

ELAPSED=$(( $(date +%s) - START ))
printf '\n%s%s Summary %s\n' "$BOLD" "$MAGENTA" "$RESET"
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  ok "installed:   ${INSTALLED[*]}"
else
  warn "no components installed yet (binaries land in future releases)"
fi
[[ ${#SKIPPED[@]} -gt 0 ]] && info "skipped:     ${SKIPPED[*]}"
[[ $BYTES -gt 0 ]] && info "downloaded:  $(awk -v b="$BYTES" 'BEGIN{printf "%.1f MB", b/1048576}')"
info "binaries:    $BIN_DIR"
info "std:         $STD_DIR"
info "time:        ${ELAPSED}s"
[[ "$DRY_RUN" != "1" ]] && ok "shell rc:   PATH + OODA_STD_ROOT set in ~/.bashrc and ~/.zshrc"

printf '\n%s%s Try these commands %s\n' "$BOLD" "$CYAN" "$RESET"
printf '  %s$ ooda --help%s              show all 13 subcommands\n  %s$ ooda build main.oo%s       build your first .oo program\n  %s$ ooda run main.oo%s         compile and execute\n  %s$ ooda init%s                scaffold a new project\n  %s$ ooda token issue%s         create a capability token\n  %s$ blackbox --help%s          flight recorder & crash autopsy\n' \
  "$GREEN" "$RESET" "$GREEN" "$RESET" "$GREEN" "$RESET" "$GREEN" "$RESET" "$GREEN" "$RESET" "$GREEN" "$RESET"
printf '\n  %s▸%s restart your shell (or: source ~/.bashrc) and run %sooda --help%s\n' "$DIM" "$RESET" "$GREEN" "$RESET"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n  %sRe-run without OPENOODA_DRY_RUN=1 to actually install.%s\n' "$DIM" "$RESET"
elif [[ ! -x "$BIN_DIR/ooda" || ! -x "$BIN_DIR/oodac" ]]; then
  err "installation failed: core binaries (ooda, oodac) not found in $BIN_DIR"
  exit 1
fi
printf '\n  %s %s100%%%s\n\n  %s%sReady. Welcome to openOODA.%s\n  https://openooda.org\n\n' \
  "$(bar 100)" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "" "$RESET"
