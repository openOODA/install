#!/usr/bin/env bash
# openOODA one-line installer
#   curl -fsSL https://openooda.org/install.sh | bash
#
# Idempotent. Detects OS/arch, downloads the latest release asset for
# each openOODA component, clones the standard library, and sets up
# the shell environment. Re-run is safe.
#
# Set NO_COLOR=1 to disable color.
# Set OPENOODA_DRY_RUN=1 to preview without downloading.

set -euo pipefail

# --- config -------------------------------------------------------------------

OPENOODA_HOME="${OPENOODA_HOME:-$HOME/.openooda}"
BIN_DIR="$OPENOODA_HOME/bin"
STD_DIR="$OPENOODA_HOME/std"
RELEASES="https://github.com/openOODA"
DRY_RUN="${OPENOODA_DRY_RUN:-0}"

declare -A REPOS=(
  [ooda]="ooda"   [oodac]="oodac" [oodar]="oodar"
  [opm]="opm"     [lsp]="lsp"     [mcp]="mcp"
)
declare -A BINARIES=(
  [ooda]="ooda"       [oodac]="oodac"     [oodar]="liboodar.a"
  [opm]="opm"         [lsp]="ooda-lsp"   [mcp]="ooda-mcp"
)

# --- locale + color -----------------------------------------------------------

case "${LC_ALL:-${LANG:-}}" in
  *UTF-8*|*utf8*|*UTF8*) HAS_UTF=1 ;;
  *) HAS_UTF=0 ;;
esac
if [[ $HAS_UTF -eq 1 ]]; then FILL="▰"; EMPTY="▱"; else FILL="#"; EMPTY="-"; fi

USE_COLOR=1
if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then USE_COLOR=0; fi
C() { [[ $USE_COLOR -eq 1 ]] && printf '\033[%sm' "$1" || true; }
RESET=$(C 0); BOLD=$(C 1); DIM=$(C 2)
CYAN=$(C 36); GREEN=$(C 32); YELLOW=$(C 33); RED=$(C 31)
MAGENTA=$(C 35); GRAY=$(C 90); BLUE=$(C 34)

# --- UI primitives -------------------------------------------------------------

# bar <pct> [width] — filled + empty blocks, colored
bar() {
  local pct=$1 width=${2:-30}
  local filled=$((pct * width / 100))
  [[ $filled -gt $width ]] && filled=$width
  [[ $filled -lt 0     ]] && filled=0
  local empty=$((width - filled))
  printf '%s' "$GREEN"
  printf '%*s' "$filled" '' | tr ' ' "$FILL"
  printf '%*s' "$empty"  '' | tr ' ' "$EMPTY"
  printf '%s' "$RESET"
}

# spinner <pid> — animate while pid is alive
spinner() {
  local pid=$1
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s ' "$CYAN" "${frames[i++ % ${#frames[@]}]}" "$RESET"
    sleep 0.1
  done
  printf '\r'
}

# overwrite-bar <done> <total> — render the bar on the current line
overwrite_bar() {
  local done=$1 total=$2
  local pct=$(( (done * 100 + total / 2) / total ))
  printf '\r  %s %s%s%3d%%%s (%d/%d)' \
    "$(bar $pct)" "$BOLD" "$MAGENTA" "$pct" "$RESET" "$done" "$total"
}

ok()   { printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED"    "$RESET" "$*" >&2; }
skip() { printf '  %s⊘%s %s\n' "$YELLOW" "$RESET" "$*"; }
info() { printf '  %s•%s %s\n' "$GRAY"   "$RESET" "$*"; }

# --- version pin loading ------------------------------------------------------

declare -A PINS=()
load_pins() {
  local f
  f="$(dirname "${BASH_SOURCE[0]:-$0}")/versions.toml"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*([a-zA-Z]+)[[:space:]]*=[[:space:]]*\"(v[0-9]+\.[0-9]+\.[0-9]+)\" ]] || continue
    PINS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  done < "$f"
}

release_url() {
  local tag="${PINS[$1]:-latest}"
  echo "${RELEASES}/${REPOS[$1]}/releases/${tag}/download/${BINARIES[$1]}-${OS}-${ARCH}"
}

# --- "what's new" line (best-effort) ------------------------------------------

whatnew() {
  local body
  body=$(curl -sSL --max-time 3 "https://api.github.com/repos/openOODA/openOODA/releases/latest" 2>/dev/null \
    | grep -oE '"body":[[:space:]]*"[^"]*"' | head -1 \
    | sed -E 's/^"body":[[:space:]]*"([^"]*)".*/\1/')
  if [[ -n "$body" ]]; then
    local first
    first=$(printf '%s' "$body" | head -1 | tr -d '\r' | head -c 100)
    printf '  %s↳%s latest: %s%s%s\n' "$DIM" "$RESET" "$DIM" "$first" "$RESET"
  fi
}

# --- per-component install (spinner + result) ---------------------------------

INSTALLED=()
SKIPPED=()
BYTES=0

install_component() {
  local key="$1" dest="$BIN_DIR/${BINARIES[$1]}" url code
  url="$(release_url "$key")"

  printf '  %s%s%s\n' "$BOLD" "$key" "$RESET"

  if [[ "$DRY_RUN" == "1" ]]; then
    code=$(curl -sSL -o /dev/null -w '%{http_code}' -I "$url" 2>/dev/null || echo 000)
    if [[ "$code" == "200" || "$code" == "302" ]]; then
      ok "[dry-run] would install $(basename "$dest")"
      INSTALLED+=("$key")
    else
      skip "[dry-run] $key not yet shipped for $OS-$ARCH"
      SKIPPED+=("$key")
    fi
    return
  fi

  local codefile="/tmp/openooda-curl.$$.$key"
  (
    code=$(curl -sSL -o "$dest.tmp" -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    echo "$code" > "$codefile"
  ) &
  local pid=$!

  # "still working" hint at 8s
  (
    sleep 8
    if kill -0 "$pid" 2>/dev/null; then
      printf '\n  %s(taking a moment; press Ctrl-C to cancel)%s\n' "$DIM" "$RESET" >&2
    fi
  ) &
  local slow_pid=$!

  spinner "$pid"
  wait "$pid" 2>/dev/null || true
  kill "$slow_pid" 2>/dev/null || true
  wait "$slow_pid" 2>/dev/null || true

  code=$(cat "$codefile" 2>/dev/null || echo 000)
  rm -f "$codefile"

  if [[ "$code" == "200" || "$code" == "302" ]] && [[ -s "$dest.tmp" ]]; then
    mv "$dest.tmp" "$dest"
    chmod +x "$dest"
    local size; size=$(wc -c < "$dest" 2>/dev/null || echo 0)
    BYTES=$((BYTES + size))
    local mb; mb=$(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}')
    ok "installed $(basename "$dest") (${mb} MB)"
    INSTALLED+=("$key")
  else
    rm -f "$dest" "$dest.tmp"
    skip "$key not yet shipped for $OS-$ARCH"
    SKIPPED+=("$key")
  fi
}

# --- shell rc -----------------------------------------------------------------

setup_shell_rc() {
  local l1='export PATH="$HOME/.openooda/bin:$PATH"'
  local l2='export OODA_STD_ROOT="$HOME/.openooda/std"'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ ! -e "$rc" ]]; then
      : >> "$rc" 2>/dev/null || continue
    fi
    if grep -Fqx "$l1" "$rc" 2>/dev/null; then
      info "$(basename "$rc") already has openOODA exports"
    else
      printf '\n# openOODA\n%s\n%s\n' "$l1" "$l2" >> "$rc"
      ok "$(basename "$rc") updated"
    fi
  done
}

# --- main ---------------------------------------------------------------------

START=$(date +%s)

# detect
OS="$(uname -s)"; case "$OS" in Linux) OS=linux ;; Darwin) OS=darwin ;;
  *) err "unsupported OS: $OS (need linux or darwin)"; exit 1 ;; esac
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) err "unsupported arch: $ARCH (need x86_64 or arm64)"; exit 1 ;; esac

# welcome
printf '\n'
printf '  %s%sobserve → orient → decide → act →%s\n' "$DIM$MAGENTA" "" "$RESET"
printf '\n'
printf '  %s%sopenOODA%s — Sovereign Systems Language for the AI Era\n' \
  "$BOLD$MAGENTA" "" "$RESET"
whatnew
printf '  %shost: %s/%s%s\n' "$DIM" "$OS" "$ARCH" "$RESET"
printf '  %sWelcome, %s%s%s.%s\n' "$DIM" "$CYAN" "${USER:-friend}" "$RESET" "$RESET"
[[ "$DRY_RUN" == "1" ]] && printf '  %s[DRY RUN — no downloads, no shell-rc edits]%s\n' "$YELLOW" "$RESET"
printf '\n'

TOTAL=9  # 1 detect + 6 components + 1 std + 1 shell
done=0
mkdir -p "$BIN_DIR"

# step 1: detect
ok "install dir: $BIN_DIR"
done=$((done + 1)); overwrite_bar "$done" "$TOTAL"; printf '\n'

# step 2: components
load_pins
for key in ooda oodac oodar opm lsp mcp; do
  install_component "$key"
  done=$((done + 1)); overwrite_bar "$done" "$TOTAL"; printf '\n'
done

# step 3: std
if [[ "$DRY_RUN" == "1" ]]; then
  skip "[dry-run] skipping std clone"
elif [[ -d "$STD_DIR" ]] && [[ -f "$STD_DIR/ANCHOR.oo" ]]; then
  ok "std already at $STD_DIR"
elif ! command -v git >/dev/null 2>&1; then
  warn "git not found; skipping std clone"
  warn "  install git, then: git clone --depth 1 https://github.com/openOODA/std $STD_DIR"
else
  info "cloning openOODA/std ..."
  (git clone --depth 1 https://github.com/openOODA/std "$STD_DIR" >/dev/null 2>&1) &
  spinner $!
  wait $! 2>/dev/null || true
  if [[ -d "$STD_DIR" ]] && [[ -f "$STD_DIR/ANCHOR.oo" ]]; then
    ok "cloned to $STD_DIR"
  else
    warn "clone may have failed; check $STD_DIR"
  fi
fi
done=$((done + 1)); overwrite_bar "$done" "$TOTAL"; printf '\n'

# step 4: shell
if [[ "$DRY_RUN" == "1" ]]; then
  skip "[dry-run] skipping shell rc"
else
  setup_shell_rc
fi
done=$((done + 1)); overwrite_bar "$done" "$TOTAL"; printf '\n'

# --- summary ------------------------------------------------------------------

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
if [[ "$DRY_RUN" != "1" ]]; then
  ok "shell rc:   PATH + OODA_STD_ROOT set in ~/.bashrc and ~/.zshrc"
fi

# --- CLI command list --------------------------------------------------------

printf '\n%s%s Try these commands %s\n' "$BOLD" "$CYAN" "$RESET"
printf '  %s$ ooda --help%s              show all 13 subcommands\n' "$GREEN" "$RESET"
printf '  %s$ ooda build main.oo%s       build your first .oo program\n' "$GREEN" "$RESET"
printf '  %s$ ooda run main.oo%s         compile and execute\n' "$GREEN" "$RESET"
printf '  %s$ ooda init%s                scaffold a new project\n' "$GREEN" "$RESET"
printf '  %s$ ooda install openOODA/std%s  install or upgrade std\n' "$GREEN" "$RESET"
printf '  %s$ ooda token issue%s         create a capability token\n' "$GREEN" "$RESET"
printf '\n'
printf '  %s▸%s restart your shell (or: source ~/.bashrc) and run %sooda --help%s\n' \
  "$DIM" "$RESET" "$GREEN" "$RESET"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n  %sRe-run without OPENOODA_DRY_RUN=1 to actually install.%s\n' "$DIM" "$RESET"
fi

# final closing bar
printf '\n  %s %s100%%%s\n\n' "$(bar 100)" "$BOLD$MAGENTA" "$RESET"
printf '  %s%sReady. Welcome to openOODA.%s\n' "$BOLD$MAGENTA" "" "$RESET"
printf '  https://openooda.org\n\n'
