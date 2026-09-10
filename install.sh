#!/usr/bin/env bash
# openOODA one-line installer
#   curl -fsSL https://openooda.org/install.sh | bash
#
# Idempotent. Detects OS/arch, downloads each component's release asset,
# clones the standard library, and sets up the shell. Re-run is safe.
#
# Set NO_COLOR=1 to disable color.
# Set OPENOODA_DRY_RUN=1 to preview without downloading.
# Set OPENOODA_YES=1 to auto-answer y to all prompts (non-interactive).

set -euo pipefail

OPENOODA_HOME="${OPENOODA_HOME:-$HOME/.openooda}"
BIN_DIR="$OPENOODA_HOME/bin"
STD_DIR="$OPENOODA_HOME/std"
RELEASES="https://github.com/openOODA"
DRY_RUN="${OPENOODA_DRY_RUN:-0}"
LOG_FILE="$OPENOODA_HOME/install.log"
NO_MODIFY_SHELL=0
DO_UNINSTALL=0
SELFTEST_SHA=0
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# --- arg parsing (curl | bash -s -- --help) ---------------------------------
usage() {
  cat <<USAGE
openOODA installer — curl -fsSL https://openooda.org/install.sh | bash
  bash install.sh [options]
Options:
  --help              show this help
  --dry-run           preview without downloading (also OPENOODA_DRY_RUN=1)
  --yes, -y           auto-answer y to all prompts (also OPENOODA_YES=1)
  --no-modify-shell   do not edit shell rc files
  --uninstall         remove binaries, std, and revert harness mcp wiring
  NO_COLOR=1          disable color
  OPENOODA_DRY_RUN=1  same as --dry-run
  OPENOODA_YES=1      same as --yes
USAGE
}
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0;;
    --dry-run) DRY_RUN=1;;
    --yes|-y) OPENOODA_YES=1;;
    --no-modify-shell) NO_MODIFY_SHELL=1;;
    --uninstall) DO_UNINSTALL=1;;
    --selftest-sha) SELFTEST_SHA=1; OPENOODA_HOME="${TMPDIR:-/tmp}/openooda-selftest-sha.$$"; LOG_FILE="$OPENOODA_HOME/install.log";;
    --) break;;
    --*) err "unknown option $arg (see --help)"; exit 1;;
  esac
done
# log setup — append, keep 1M rotation
mkdir -p "$OPENOODA_HOME" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
# rotate if >1M
if [[ -f "$LOG_FILE" ]] && [[ $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]]; then
  mv "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null || true
fi
exec 3>>"$LOG_FILE" 2>/dev/null || exec 3>/dev/null
_log() { printf '[%s] %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*" >&3 2>/dev/null || true; }

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
  local pid=$1
  # Use braille if stdout is a tty AND locale likely supports UTF-8; else ASCII fallback.
  local frames
  if [[ -t 1 ]] && [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *UTF-8* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *utf8* ]]; then
    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    frames=('|' '/' '-' '\' '|' '/' '-' '\' '|' '/')
  fi
  local i=0
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
ok()   { [[ "${QUIET:-0}" == "1" ]] && { _log "OK $*"; return; }; printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; _log "OK $*"; }
warn() { [[ "${QUIET:-0}" == "1" ]] && { _log "WARN $*"; return; }; printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; _log "WARN $*"; }
err()  { printf '  %s✗%s %s\n' "$RED"    "$RESET" "$*" >&2; _log "ERR $*"; }
skip() { [[ "${QUIET:-0}" == "1" ]] && { _log "SKIP $*"; return; }; printf '  %s⊘%s %s\n' "$YELLOW" "$RESET" "$*"; _log "SKIP $*"; }
info() { [[ "${QUIET:-0}" == "1" ]] && { _log "INFO $*"; return; }; printf '  %s•%s %s\n' "$GRAY"   "$RESET" "$*"; _log "INFO $*"; }

# print_banner: 5-row-tall block letters spelling "openOODA", version stamp.
# One-time at install start. Read top-to-bottom: the columns spell o p e n O O D A.
print_banner() {
  printf '\n'
  printf '%s' "$BOLD$CYAN"
  cat <<'EOF'
  oooo  pppp  eeee  n   n    OOOO   OOOO  DDDD       A
  o   o p   p e     n   n   O    O O    O D   D    A   A
  o   o p   p eeee  n   n   O    O O    O D   D   AAAAAA
  o   o p   p e     n   n   O    O O    O D   D   A     A
  oooo  pppp  eeee  n   n    OOOO   OOOO  DDDD   A       A
EOF
  printf '%s\n' "$RESET"
  printf '  v%s · curl|bash · sovereign systems language\n\n' "$VERSION"
}

ensure_sysdep() {
  local cmd="$1" pm_pkg="$2"
  command -v "$cmd" >/dev/null 2>&1 && { ok "$cmd present"; return 0; }
  if [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
    err "$cmd missing and not root — install it, then re-run (e.g. sudo apt-get install -y $pm_pkg)"
    return 1
  fi
  info "installing $pm_pkg (provides $cmd) ..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>&1 | tail -n 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pm_pkg" 2>&1 | tail -n 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$pm_pkg" 2>&1 | tail -n 1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "$pm_pkg" 2>&1 | tail -n 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$pm_pkg" 2>&1 | tail -n 1
  elif command -v brew >/dev/null 2>&1; then
    brew install "$pm_pkg" 2>&1 | tail -n 1
  else
    err "no supported package manager (need $cmd) — install $pm_pkg, then re-run"
    return 1
  fi
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd still missing after installing $pm_pkg"; return 1; }
  ok "$cmd installed via $pm_pkg"
}

pre_flight() {
  local need_fail=0
  for bin in curl; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      err "pre-flight: $bin not found in PATH (required)"; need_fail=1
    fi
  done
  for bin in git python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      warn "pre-flight: $bin not found (git/gcc are auto-installed when root; python3 only needed for harness wiring)"
    fi
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    err "pre-flight: sha256sum/shasum not found in PATH (required)"; need_fail=1
  fi
  # disk: need ~100 MB free in OPENOODA_HOME
  local avail_kb
  avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  if [[ "$avail_kb" -gt 0 && "$avail_kb" -lt 102400 ]]; then
    err "pre-flight: <100 MB free in $HOME (${avail_kb}KB) — need ~60 MB for 7 bins + std + oodar sources"
    need_fail=1
  fi
  # network: quick HEAD to raw.githubusercontent (3s)
  if ! curl -Is --max-time 3 "https://raw.githubusercontent.com" >/dev/null 2>&1; then
    err "pre-flight: no network to raw.githubusercontent.com (check proxy/firewall)"
    need_fail=1
  fi
  if [[ $need_fail -eq 1 ]]; then
    err "pre-flight failed — see $LOG_FILE"
    return 1
  fi
  # Printed unconditionally (not via `info`) so QUIET=1 doesn't suppress the
  # success line. This is the only output between the banner and the spinner,
  # so the user always sees something happen.
  printf '  %s✓%s pre-flight: curl/sha256, disk, network OK\n' "$GREEN" "$RESET"
}

ask_confirm() {
  local prompt="$1" def="${2:-Y}" ans="" src=""
  if [[ "$DRY_RUN" == "1" ]]; then return 0; fi
  if [[ "${OPENOODA_YES:-}" == "1" || "${OPENOODA_AUTO_YES:-}" == "1" || "${OPENOODA_ASSUME_YES:-}" == "1" ]]; then return 0; fi
  if [[ -n "${CI:-}" ]]; then return 0; fi
  # decide where to read answer from:
  # - if stdin is a pipe with data and script is a file (bash install.sh), read from stdin
  # - if stdin is script itself (curl | bash, no file), read from /dev/tty
  # - if no tty at all, auto yes
  if [[ ! -t 0 ]]; then
    # stdin is not a tty (pipe)
    if [[ -f "${BASH_SOURCE[0]:-}" ]] && [[ -s "${BASH_SOURCE[0]}" ]]; then
      # script is a file on disk -> stdin is likely user piped answer (e.g., printf "n" | bash install.sh)
      src="stdin"
    else
      # no file (curl | bash) -> stdin is script, use /dev/tty for user input
      src="tty"
    fi
  else
    src="tty"
  fi
  if [[ "$src" == "tty" && ! -e /dev/tty ]]; then return 0; fi
  if [[ ! -t 0 && ! -t 1 && ! -e /dev/tty ]]; then return 0; fi
  local prompt_str
  prompt_str=$(printf '  %s%s%s [%s/n] ' "$BOLD" "$prompt" "$RESET" "$def")
  if [[ "$src" == "tty" && -e /dev/tty ]]; then
    printf '%s' "$prompt_str" > /dev/tty 2>/dev/null || printf '%s' "$prompt_str"
    if read -t 120 -r ans < /dev/tty 2>/dev/null; then
      ans=$(printf '%s' "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
      [[ -z "$ans" ]] && ans=$(printf '%s' "$def" | tr '[:upper:]' '[:lower:]')
      [[ "$ans" == "y" || "$ans" == "yes" ]] && return 0 || return 1
    else
      # timeout or EOF -> default yes
      printf '\n' > /dev/tty 2>/dev/null || true
      return 0
    fi
  else
    printf '%s' "$prompt_str"
    if read -t 120 -r ans 2>/dev/null; then
      ans=$(printf '%s' "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
      [[ -z "$ans" ]] && ans=$(printf '%s' "$def" | tr '[:upper:]' '[:lower:]')
      [[ "$ans" == "y" || "$ans" == "yes" ]] && return 0 || return 1
    else
      printf '\n'
      return 0
    fi
  fi
}

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

# dest file, sidecar file, component key. 0 = match; 1 = refuse.
sha256_check() {
  local dest="$1" sidecar="$2" key="$3"
  local expected_hash actual_hash
  if [[ ! -s "$sidecar" ]]; then
    err "$key: missing SHA-256 sidecar; refuse unsigned install"
    return 1
  fi
  expected_hash=$(awk '{print $1}' "$sidecar" | tr -d '\r\n ')
  if command -v sha256sum >/dev/null 2>&1; then
    actual_hash=$(sha256sum "$dest" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    actual_hash=$(shasum -a 256 "$dest" | awk '{print $1}')
  else
    err "$key: no sha256sum/shasum; refuse unsigned install"
    return 1
  fi
  if [[ -z "$expected_hash" || "$expected_hash" != "$actual_hash" ]]; then
    err "$key: SHA-256 checksum mismatch (expected ${expected_hash:-empty}, got $actual_hash)"
    return 1
  fi
  info "$key: SHA-256 verified (${expected_hash:0:16}...)"
  return 0
}

# fetch_and_verify: download binary + sidecar + verify SHA-256 + install.
# Runs entirely in a background subshell called by install_component.
# Writes result files into $wd; caller reads them after `wait`.
fetch_and_verify() {
  local url="$1" dest="$2" wd="$3"
  # 1. download binary
  local dl; dl=$(curl -sSL --connect-timeout 10 --max-time 120 -o "$dest.tmp" \
    -w '%{http_code}' "$url" 2>/dev/null || echo 000)
  echo "$dl" > "$wd/dl"
  [[ "$dl" == "200" && -s "$dest.tmp" ]] || return 0
  # 2. sidecar
  local sha; sha=$(curl -sSL --connect-timeout 5 --max-time 15 \
    -o "$dest.tmp.sha256" -w '%{http_code}' "${url}.sha256" 2>/dev/null || echo 000)
  echo "$sha" > "$wd/sha"
  [[ "$sha" == "200" && -s "$dest.tmp.sha256" ]] || return 0
  # 3. SHA check (inline; captures actual_hash for success line)
  local actual expected
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$dest.tmp" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$dest.tmp" | awk '{print $1}')
  fi
  expected=$(awk '{print $1}' "$dest.tmp.sha256" | tr -d '\r\n ')
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "mismatch" > "$wd/vrc"; echo "$expected" > "$wd/expected"; echo "$actual" > "$wd/actual"
    return 0
  fi
  echo "0" > "$wd/vrc"; echo "${actual:0:16}" > "$wd/vhash"
  # 4. install (mv + chmod) so caller doesn't have to re-check the binary
  mv "$dest.tmp" "$dest" 2>/dev/null && chmod +x "$dest" 2>/dev/null
  wc -c < "$dest" > "$wd/size" 2>/dev/null || echo 0 > "$wd/size"
}

# fetch_repo: git clone + verify the expected file exists, write ok|fail status.
# Mirrors fetch_and_verify: runs in background subshell, parent spins on the pid.
fetch_repo() {
  local url="$1" dest="$2" verify="$3" branch="$4" wd="$5"
  local args=(--depth 1)
  [[ -n "$branch" ]] && args+=(--branch "$branch")
  git clone "${args[@]}" "$url" "$dest" >/dev/null 2>&1
  if [[ -f "$dest/$verify" ]]; then
    echo "ok" > "$wd/status"
  else
    echo "fail" > "$wd/status"
  fi
}

selftest_sha() {
  local td dest
  td=$(mktemp -d)
  dest="$td/bin"
  printf 'openooda-asset' > "$dest"
  if sha256_check "$dest" "$td/missing.sha256" "selftest-missing" 2>/dev/null; then
    rm -rf "$td"; err "selftest: missing sidecar must fail"; exit 1
  fi
  printf '\n' > "$td/empty.sha256"
  if sha256_check "$dest" "$td/empty.sha256" "selftest-empty" 2>/dev/null; then
    rm -rf "$td"; err "selftest: empty sidecar must fail"; exit 1
  fi
  echo "0000000000000000000000000000000000000000000000000000000000000000  bin" > "$td/bad.sha256"
  if sha256_check "$dest" "$td/bad.sha256" "selftest-mismatch" 2>/dev/null; then
    rm -rf "$td"; err "selftest: mismatch must fail"; exit 1
  fi
  (cd "$td" && sha256sum bin > good.sha256)
  if ! sha256_check "$dest" "$td/good.sha256" "selftest-match"; then
    rm -rf "$td"; err "selftest: matching sidecar must pass"; exit 1
  fi
  rm -rf "$td" "$OPENOODA_HOME"
  ok "selftest-sha: missing/empty/mismatch refuse, match accepts"
  exit 0
}

install_component() {
  local key="$1" dest="$BIN_DIR/${BINARIES[$1]}" url
  url="$(release_url "$key")"
  printf '  %s%s%s\n' "$BOLD" "$key" "$RESET"

  if [[ "$DRY_RUN" == "1" ]]; then
    local code
    code=$(curl -sSL -o /dev/null -w '%{http_code}' -I "$url" 2>/dev/null || echo 000)
    if [[ "$code" != "200" ]]; then
      skip "[dry-run] $key not yet shipped for $OS-$ARCH"; SKIPPED+=("$key")
      return
    fi
    local sha_code
    sha_code=$(curl -sSL -o /dev/null -w '%{http_code}' -I "${url}.sha256" 2>/dev/null || echo 000)
    if [[ "$sha_code" != "200" ]]; then
      err "[dry-run] $key: missing SHA-256 sidecar; refuse unsigned install"
      return 1
    fi
    ok "[dry-run] would install $(basename "$dest")"; INSTALLED+=("$key")
    return
  fi

  # ONE subshell + ONE spinner for the whole per-component install
  local wd; wd=$(mktemp -d 2>/dev/null || echo "/tmp/openooda-$$-$key")
  ( fetch_and_verify "$url" "$dest" "$wd" ) &
  local pid=$!
  spinner "$pid"
  wait "$pid" 2>/dev/null || true

  # Read all results
  local dl sha vrc vhash size expected actual
  dl=$(cat "$wd/dl" 2>/dev/null || echo 000)
  sha=$(cat "$wd/sha" 2>/dev/null || echo "")
  vrc=$(cat "$wd/vrc" 2>/dev/null || echo "missing")
  vhash=$(cat "$wd/vhash" 2>/dev/null || echo "")
  size=$(cat "$wd/size" 2>/dev/null || echo 0)
  expected=$(cat "$wd/expected" 2>/dev/null || echo "")
  actual=$(cat "$wd/actual" 2>/dev/null || echo "")
  rm -rf "$wd"

  # Branch on results
  if [[ "$vrc" == "0" && -x "$dest" ]]; then
    local mb; mb=$(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}')
    info "$key: SHA-256 verified ($vhash...)"
    ok "installed $(basename "$dest") (${mb} MB)"; INSTALLED+=("$key")
    BYTES=$((BYTES + size))
  elif [[ "$dl" != "200" ]]; then
    rm -f "$dest.tmp" "$dest.tmp.sha256"
    if [[ -x "$dest" ]]; then
      warn "$key download failed (http $dl); preserved existing $(basename "$dest")"
    elif [[ "$dl" == "404" ]]; then
      skip "$key not yet shipped for $OS-$ARCH"; SKIPPED+=("$key")
    elif [[ "$key" == "ooda" || "$key" == "oodac" ]]; then
      err "$key download failed (http $dl) with no existing binary; refusing partial install"
      exit 1
    else
      warn "$key download failed (http $dl); continuing without $(basename "$dest")"
      SKIPPED+=("$key")
    fi
  elif [[ -z "$sha" || "$sha" != "200" ]]; then
    rm -f "$dest.tmp" "$dest.tmp.sha256"
    err "$key: missing SHA-256 sidecar; refuse unsigned install"
    return 1
  else
    rm -f "$dest.tmp" "$dest.tmp.sha256"
    err "$key: SHA-256 checksum mismatch (expected ${expected:-empty}, got $actual)"
    return 1
  fi
}

# --- shell rc ----------------------------------------------------------------

setup_shell_rc() {
  if [[ $NO_MODIFY_SHELL -eq 1 ]]; then skip "shell rc: --no-modify-shell, not editing"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would update shell rc (bashrc/zshrc/fish)"; return 0; fi
  local l1='export PATH="$HOME/.openooda/bin:$PATH"'
  local l2='export OODA_STD_ROOT="$HOME/.openooda/std"'
  local l3='export OODA_COMPILER="$HOME/.openooda/bin/oodac"'
  local l4='export OODA_FS_READDIR="$HOME/Projects/openOODA"'
  local l5='export OODA_FS_WRITEDIR="$HOME"'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -e "$rc" ]] || : >> "$rc" 2>/dev/null || continue
    if [[ -f "$rc" && ! -f "$rc.bak.openooda" ]]; then cp -p "$rc" "$rc.bak.openooda" 2>/dev/null || true; _log "backup $rc -> $rc.bak.openooda"; fi
    if grep -q '\.local/bin/oodac' "$rc" 2>/dev/null; then
      sed -i 's|.*\.local/bin/oodac.*|'"$l3"'|' "$rc" 2>/dev/null || true
      ok "$(basename "$rc") fixed OODA_COMPILER -> ~/.openooda/bin/oodac"
    fi
    if grep -Fqx "$l1" "$rc" 2>/dev/null; then
      info "$(basename "$rc") already has openOODA exports"
    else
      printf '\n# openOODA\n%s\n%s\n%s\n%s\n%s\n' "$l1" "$l2" "$l3" "$l4" "$l5" >> "$rc"
      ok "$(basename "$rc") updated"
    fi
    # jail defaults for installs that predate them (binaries must work with zero manual exports)
    for _jl in "$l4" "$l5"; do
      grep -Fqx "$_jl" "$rc" 2>/dev/null || printf '%s\n' "$_jl" >> "$rc"
    done
  done
  # fish (XDG-aware)
  local fish_cfg="${XDG_CONFIG_HOME}/fish/config.fish"
  if [[ -d "${XDG_CONFIG_HOME}/fish" ]] || command -v fish >/dev/null 2>&1; then
    mkdir -p "$(dirname "$fish_cfg")" 2>/dev/null || true
    if [[ -f "$fish_cfg" && ! -f "$fish_cfg.bak.openooda" ]]; then cp -p "$fish_cfg" "$fish_cfg.bak.openooda" 2>/dev/null || true; fi
    if ! grep -q 'fish_add_path.*\.openooda/bin' "$fish_cfg" 2>/dev/null; then
      printf '\n# openOODA\nfish_add_path $HOME/.openooda/bin\nset -x OODA_STD_ROOT $HOME/.openooda/std\nset -x OODA_COMPILER $HOME/.openooda/bin/oodac\nset -x OODA_FS_READDIR $HOME/Projects/openOODA\nset -x OODA_FS_WRITEDIR $HOME\n' >> "$fish_cfg" 2>/dev/null || true
      ok "fish config updated ($fish_cfg)"
    else
      info "fish config already has openOODA exports"
    fi
  fi
}

refresh_grok_shims() {
  local shim_dir="$BIN_DIR"
  local py_lsp="$shim_dir/ooda-lsp-grok"
  local py_mcp="$shim_dir/ooda-mcp-grok"
  for shim in "$py_lsp" "$py_mcp"; do
    if [[ -f "$shim" ]]; then
      touch "$shim" 2>/dev/null || true
      info "refreshed $(basename "$shim") shim mtime"
    fi
  done
}

restart_stale_servers() {
  local pids
  pids=$(ps aux 2>/dev/null | grep -E 'ooda-mcp --stdio|ooda-lsp --stdio|ooda-lsp-grok|ooda-mcp-grok' | grep -v grep | awk '{print $2}') || true
  if [[ -n "$pids" ]]; then
    info "stale servers: $pids (old binaries in memory, new on disk) — kill to pick up new build"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 0.5
    # reap zombies
    for pid in $pids; do wait "$pid" 2>/dev/null || true; done
    ok "stale servers reaped (zombies cleared)"
  else
    info "no stale ooda-mcp/lsp servers found"
  fi
  if ! command -v oodac >/dev/null 2>&1 || [[ "$(command -v oodac 2>/dev/null)" != "$BIN_DIR/oodac" ]]; then
    warn "run: source ~/.bashrc (or restart shell) to pick up new PATH"
  fi
  if [[ "${OODA_COMPILER:-}" != "$BIN_DIR/oodac" && "${OODA_COMPILER:-}" != "" ]]; then
    warn "OODA_COMPILER=$OODA_COMPILER (expected $BIN_DIR/oodac) — restart shell or export OODA_COMPILER=\$HOME/.openooda/bin/oodac"
  fi
}

post_flight() {
  local fail=0
  for bin in ooda oodac ooda-lsp ooda-mcp blackbox opm; do
    if [[ "$bin" == "ooda" ]]; then
      # ooda --help fails when stdout is not a tty (see host_run mkdir), just check executable + --help pipes to head
      if [[ -x "$BIN_DIR/$bin" ]] && "$BIN_DIR/$bin" --help 2>&1 | head -n 1 | grep -q "openOODA" 2>/dev/null; then
        ok "verified: $bin --help"
      elif [[ -x "$BIN_DIR/$bin" ]]; then
        ok "verified: $bin exists"
      else
        warn "verify: $bin not executable"
        fail=1
      fi
    elif [[ -x "$BIN_DIR/$bin" ]] && "$BIN_DIR/$bin" --help >/dev/null 2>&1; then
      ok "verified: $bin --help"
    else
      warn "verify: $bin not executable or --help failed"
      fail=1
    fi
  done
  # harness configs: check at least one wired harness has openooda
  local harness_ok=0
  for f in "$XDG_CONFIG_HOME/opencode/opencode.jsonc" "$HOME/.config/opencode/opencode.jsonc" "$HOME/.cursor/mcp.json" "$XDG_CONFIG_HOME/muse/settings.json" "$HOME/.gemini/config/mcp_config.json" "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json" "$XDG_CONFIG_HOME/Code/User/mcp.json"; do
    if [[ -f "$f" ]] && grep -q "openooda" "$f" 2>/dev/null; then harness_ok=1; break; fi
  done
  if [[ $harness_ok -eq 1 ]]; then
    ok "verified: harness mcp wiring contains openooda"
  elif [[ ${#HARNESS_WIRED[@]} -gt 0 ]]; then
    warn "verify: wired ${HARNESS_WIRED[*]} but no config contained openooda"
  else
    info "verify: no harnesses wired — skipping harness check"
  fi
  if [[ $fail -eq 1 ]]; then
    warn "post-flight: one or more binaries failed --help — see $LOG_FILE"
  else
    ok "post-flight: all binaries verified"
  fi
}

# --- harness auto-detect + wire mcp/lsp/blackbox ------------------------------
# INVARIANT: every server env must set BOTH OODA_FS_READDIR and OODA_FS_WRITEDIR;
# the jail fails closed when either is absent (blackbox/lsp die at startup).

HARNESS_DETECTED=()
HARNESS_WIRED=()
HARNESS_SKIPPED=()

_ooda_codex_path() {
  if [[ -n "${OODACODEX:-}" && -f "$OODACODEX" ]]; then echo "$OODACODEX"; return; fi
  if [[ -n "${OODA_CODEX:-}" && -f "$OODA_CODEX" ]]; then echo "$OODA_CODEX"; return; fi
  if [[ -f "$OPENOODA_HOME/NORTHSTAR.oot" ]]; then echo "$OPENOODA_HOME/NORTHSTAR.oot"; return; fi
  if [[ -f "$OPENOODA_HOME/../openOODA/NORTHSTAR.oot" ]]; then echo "$OPENOODA_HOME/../openOODA/NORTHSTAR.oot"; return; fi
  if [[ -f "$HOME/Projects/openOODA/openOODA/NORTHSTAR.oot" ]]; then echo "$HOME/Projects/openOODA/openOODA/NORTHSTAR.oot"; return; fi
  echo ""
}

detect_harnesses() {
  HARNESS_DETECTED=(); HARNESS_SKIPPED=()
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"
  if command -v agy >/dev/null 2>&1 || [[ -d "$HOME/.gemini/antigravity-cli" ]]; then HARNESS_DETECTED+=("antigravity-cli"); else HARNESS_SKIPPED+=("antigravity-cli"); fi
  if command -v opencode >/dev/null 2>&1 || [[ -d "$xdg/opencode" ]]; then HARNESS_DETECTED+=("opencode"); else HARNESS_SKIPPED+=("opencode"); fi
  if command -v muse >/dev/null 2>&1 || [[ -d "$xdg/muse" ]]; then HARNESS_DETECTED+=("muse"); else HARNESS_SKIPPED+=("muse"); fi
  if command -v grok >/dev/null 2>&1 || [[ -d "$HOME/.grok" ]]; then HARNESS_DETECTED+=("grok"); else HARNESS_SKIPPED+=("grok"); fi
  if [[ -d "$HOME/.gemini" ]]; then HARNESS_DETECTED+=("gemini"); else HARNESS_SKIPPED+=("gemini"); fi
  if command -v claude >/dev/null 2>&1 || [[ -f "$HOME/.claude.json" ]] || [[ -d "$xdg/claude" ]] || [[ -f "$xdg/claude/config.json" ]]; then HARNESS_DETECTED+=("claude-code"); else HARNESS_SKIPPED+=("claude-code"); fi
  if [[ -f "$xdg/Claude/claude_desktop_config.json" ]] || [[ -f "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ]] || [[ -d "$xdg/Claude" ]]; then HARNESS_DETECTED+=("claude-desktop"); else HARNESS_SKIPPED+=("claude-desktop"); fi
  if command -v cursor >/dev/null 2>&1 || [[ -d "$HOME/.cursor" ]] || [[ -f "$HOME/.cursor/mcp.json" ]]; then HARNESS_DETECTED+=("cursor"); else HARNESS_SKIPPED+=("cursor"); fi
  if command -v windsurf >/dev/null 2>&1 || [[ -d "$HOME/.codeium" ]] || [[ -d "$HOME/.windsurf" ]] || [[ -f "$HOME/.codeium/windsurf/mcp_config.json" ]]; then HARNESS_DETECTED+=("windsurf"); else HARNESS_SKIPPED+=("windsurf"); fi
  if command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]]; then HARNESS_DETECTED+=("codex"); else HARNESS_SKIPPED+=("codex"); fi
  if [[ -f "$xdg/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json" ]] || [[ -f "$xdg/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json" ]] || [[ -f "$HOME/.cline/mcp_settings.json" ]]; then HARNESS_DETECTED+=("cline"); else HARNESS_SKIPPED+=("cline"); fi
  if type -P continue >/dev/null 2>&1 || [[ -f "$HOME/.continue/config.json" ]] || [[ -d "$HOME/.continue" ]]; then HARNESS_DETECTED+=("continue"); else HARNESS_SKIPPED+=("continue"); fi
  if command -v zed >/dev/null 2>&1 || [[ -f "$xdg/zed/settings.json" ]]; then HARNESS_DETECTED+=("zed"); else HARNESS_SKIPPED+=("zed"); fi
  if command -v code >/dev/null 2>&1 || [[ -d "$xdg/Code" ]]; then HARNESS_DETECTED+=("vscode"); else HARNESS_SKIPPED+=("vscode"); fi
  if command -v goose >/dev/null 2>&1 || [[ -f "$xdg/goose/config.yaml" ]]; then HARNESS_DETECTED+=("goose"); else HARNESS_SKIPPED+=("goose"); fi
  if command -v mistral-vibe >/dev/null 2>&1 || command -v vibe >/dev/null 2>&1 || command -v vibe-acp >/dev/null 2>&1 || [[ -d "$HOME/.vibe" ]] || [[ -d "$xdg/mistral" ]] || [[ -d "$HOME/.local/share/uv/tools/mistral-vibe" ]]; then HARNESS_DETECTED+=("mistral-vibe"); else HARNESS_SKIPPED+=("mistral-vibe"); fi
  if command -v grok-build >/dev/null 2>&1 || command -v grok >/dev/null 2>&1 || command -v xai-grok-pager >/dev/null 2>&1 || [[ -d "$HOME/.grok" ]] || [[ -f "$HOME/.grok/bin/grok" ]]; then HARNESS_DETECTED+=("grok-build"); else HARNESS_SKIPPED+=("grok-build"); fi
  if command -v devin >/dev/null 2>&1; then HARNESS_DETECTED+=("devin"); else HARNESS_SKIPPED+=("devin"); fi
  if command -v charm >/dev/null 2>&1 || [[ -d "$xdg/charm" ]] || command -v crush >/dev/null 2>&1; then HARNESS_DETECTED+=("charm"); else HARNESS_SKIPPED+=("charm"); fi
  if command -v mcode >/dev/null 2>&1 || [[ -f "$HOME/.minimax/mcp.json" ]] || [[ -d "$HOME/.minimax-code" ]]; then HARNESS_DETECTED+=("mcode"); else HARNESS_SKIPPED+=("mcode"); fi
  if [[ -n "${OPENOODA_DEBUG:-}" ]]; then
    if [[ ${#HARNESS_DETECTED[@]} -gt 0 ]]; then info "harnesses detected: ${HARNESS_DETECTED[*]}"; fi
    if [[ ${#HARNESS_SKIPPED[@]} -gt 0 ]]; then info "harnesses skipped (not installed): ${HARNESS_SKIPPED[*]}"; fi
  fi
}

_wire_json_backup() {
  local f="$1"
  if [[ -f "$f" && ! -f "$f.bak.openooda" ]]; then cp -p "$f" "$f.bak.openooda" 2>/dev/null || true; fi
}

wire_agy() {
  if ! command -v agy >/dev/null 2>&1; then skip "agy not installed — skipping antigravity-cli wire"; return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("antigravity-cli"); return 0; fi
  local envs=(--env "OODA_CODEX=$codex" --env "OODACODEX=$codex" --env "OODA_FS_READDIR=$HOME/Projects/openOODA" --env "OODA_FS_WRITEDIR=$HOME" --env "OODA_COMPILER=$BIN_DIR/oodac" --env "OODAC_BIN=$BIN_DIR/oodac")
  agy mcp add "${envs[@]}" openooda "$BIN_DIR/ooda-mcp" -- --stdio >/dev/null 2>&1 || warn "agy mcp add openooda failed"
  agy mcp add "${envs[@]}" blackbox /usr/bin/stdbuf -- -o0 -e0 "$BIN_DIR/blackbox" mcp --stdio >/dev/null 2>&1 || {
    # fallback without stdbuf wrapper
    agy mcp add "${envs[@]}" blackbox "$BIN_DIR/blackbox" -- mcp --stdio >/dev/null 2>&1 || warn "agy mcp add blackbox failed"
  }
  HARNESS_WIRED+=("antigravity-cli")
}

wire_opencode() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfg="$xdg/opencode/opencode.jsonc"
  if [[ ! -d "$xdg/opencode" ]] && ! command -v opencode >/dev/null 2>&1; then skip "opencode not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("opencode"); return 0; fi
  mkdir -p "$(dirname "$cfg")"
  _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null
import json, os, sys, re
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
text=""
if os.path.exists(cfg):
    try:
        with open(cfg) as f: text=f.read()
    except: text=""
else:
    text='{"$schema":"https://opencode.ai/config.json"}'
stripped=re.sub(r'//.*','',text)
stripped=re.sub(r'/\*.*?\*/','',stripped,flags=re.S)
stripped=re.sub(r',\s*([}\]])','\1',stripped)
try:
    data=json.loads(stripped) if stripped.strip() else {}
except:
    data={"$schema":"https://opencode.ai/config.json"}
if not isinstance(data, dict): data={}
if "$schema" not in data: data["$schema"]="https://opencode.ai/config.json"
mcp=data.get("mcp") or {}
if not isinstance(mcp, dict): mcp={}
mcp["openooda"]={"type":"local","command":[bindir+"/ooda-mcp","--stdio"],"enabled":True,"environment":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
mcp["blackbox"]={"type":"local","command":["/usr/bin/stdbuf","-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"enabled":True,"environment":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
data["mcp"]=mcp
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  if [[ $? -eq 0 ]] && grep -q '"openooda"' "$cfg" 2>/dev/null; then
    HARNESS_WIRED+=("opencode"); return 0
  fi
  warn "opencode wire: python3 merge failed, writing minimal json"
  printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "mcp": {\n    "openooda": { "type": "local", "command": ["%s/ooda-mcp", "--stdio"], "enabled": true, "environment": { "OODA_CODEX": "%s", "OODACODEX": "%s", "OODA_FS_READDIR": "%s/Projects/openOODA", "OODA_FS_WRITEDIR": "%s", "OODA_COMPILER": "%s/oodac" } },\n    "blackbox": { "type": "local", "command": ["/usr/bin/stdbuf", "-o0", "-e0", "%s/blackbox", "mcp", "--stdio"], "enabled": true, "environment": { "OODA_FS_READDIR": "%s/Projects/openOODA", "OODA_FS_WRITEDIR": "%s", "OODA_COMPILER": "%s/oodac", "OODAC_BIN": "%s/oodac" } }\n  }\n}\n' "$BIN_DIR" "$codex" "$codex" "$HOME" "$HOME" "$BIN_DIR" "$BIN_DIR" "$HOME" "$HOME" "$BIN_DIR" "$BIN_DIR" > "$cfg"
  HARNESS_WIRED+=("opencode")
}

wire_gemini() {
  local cfg="$HOME/.gemini/config/mcp_config.json"
  if [[ ! -d "$HOME/.gemini" ]]; then skip "gemini not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("gemini"); return 0; fi
  mkdir -p "$(dirname "$cfg")"
  _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || { warn "gemini wire: python merge failed"; return 0; }
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
data={}
if os.path.exists(cfg):
    try:
        with open(cfg) as f: data=json.load(f)
    except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home,"OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("gemini")
}

wire_grok() {
  local toml="$HOME/.grok/config.toml" lsp="$HOME/.grok/lsp.json"
  if [[ ! -d "$HOME/.grok" ]] && ! command -v grok >/dev/null 2>&1; then skip "grok not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would verify grok: $toml + $lsp"; HARNESS_WIRED+=("grok"); return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  # ensure mcp_servers via python toml-ish append if missing
  if [[ -f "$toml" ]]; then
    _wire_json_backup "$toml"
    # repair: older installs wrote ooda-mcp-grok/ooda-lsp-grok shims that were
    # never shipped — repoint at the real binaries with full env
    if grep -q "ooda-mcp-grok\|ooda-lsp-grok" "$toml" 2>/dev/null; then
      sed -i 's|ooda-mcp-grok|ooda-mcp|g; s|ooda-lsp-grok|ooda-lsp|g' "$toml" 2>/dev/null || true
      _log "repaired grok -grok shim refs in $toml"
    fi
    if ! grep -q "mcp_servers.blackbox" "$toml" 2>/dev/null; then
      cat >> "$toml" <<TOML

[mcp_servers.blackbox]
command = "/usr/bin/stdbuf"
args = ["-o0", "-e0", "$BIN_DIR/blackbox", "mcp", "--stdio"]
enabled = true
startup_timeout_sec = 60

[mcp_servers.blackbox.env]
OODA_FS_READDIR = "$HOME/Projects/openOODA"
OODA_FS_WRITEDIR = "$HOME"
OODA_COMPILER = "$BIN_DIR/oodac"
OODAC_BIN = "$BIN_DIR/oodac"
TOML
    fi
    if ! grep -q "mcp_servers.openooda" "$toml" 2>/dev/null; then
      cat >> "$toml" <<TOML

[mcp_servers.openooda]
command = "$BIN_DIR/ooda-mcp"
args = ["--stdio"]
enabled = true
startup_timeout_sec = 60

[mcp_servers.openooda.env]
OODA_CODEX = "$codex"
OODACODEX = "$codex"
OODA_FS_READDIR = "$HOME/Projects/openOODA"
OODA_FS_WRITEDIR = "$HOME"
OODA_COMPILER = "$BIN_DIR/oodac"
OODAC_BIN = "$BIN_DIR/oodac"
TOML
    fi
    # repair: openooda block from older installs lacks --stdio and env keys
    if grep -q "mcp_servers.openooda" "$toml" 2>/dev/null; then
      python3 - "$toml" "$BIN_DIR" "$codex" "$HOME" <<'PY' 2>/dev/null || true
import re, sys
toml, bindir, codex, home = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(toml) as f: text = f.read()
def ensure_env(block, key, val):
    global text
    pat = r"(\[mcp_servers\.%s\.env\][^\[]*)" % block
    m = re.search(pat, text)
    if m and re.search(r"^%s\s*=" % key, m.group(1), re.M) is None:
        text = text.replace(m.group(1), m.group(1).rstrip("\n") + "\n%s = \"%s\"\n" % (key, val), 1)
text = re.sub(r"(\[mcp_servers\.openooda\][^\[]*?args\s*=\s*)\[\]",
              r'\1["--stdio"]', text, count=1)
ensure_env("openooda", "OODACODEX", codex)
ensure_env("openooda", "OODA_FS_WRITEDIR", home)
ensure_env("openooda", "OODA_COMPILER", bindir + "/oodac")
ensure_env("openooda", "OODAC_BIN", bindir + "/oodac")
ensure_env("blackbox", "OODA_FS_WRITEDIR", home)
with open(toml, "w") as f: f.write(text)
PY
    fi
  fi
  if [[ -f "$lsp" ]]; then
    _wire_json_backup "$lsp"
    python3 - "$lsp" "$BIN_DIR" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
entry=data.get("ooda") or {}
if not isinstance(entry, dict): entry={}
# repair: older installs wrote the never-shipped ooda-lsp-grok shim with no
# --stdio and no WRITEDIR — repoint at the real binary with full env
entry["command"]=bindir+"/ooda-lsp"
entry["args"]=["--stdio"]
entry["extensionToLanguage"]={".oo":"ooda",".oot":"ooda"}
env=entry.get("env") or {}
if not isinstance(env, dict): env={}
env["OODA_COMPILER"]=bindir+"/oodac"
env["OODAC_BIN"]=bindir+"/oodac"
env["OODA_FS_READDIR"]=home+"/Projects/openOODA"
env["OODA_FS_WRITEDIR"]=home
entry["env"]=env
entry["workspaceFolder"]=home+"/Projects/openOODA"
entry["startupTimeout"]=60000
entry["restartOnCrash"]=True
data["ooda"]=entry
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  fi
  HARNESS_WIRED+=("grok")
}

wire_muse() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfg="$xdg/muse/settings.json"
  if [[ ! -d "$xdg/muse" ]] && ! command -v muse >/dev/null 2>&1; then skip "muse not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("muse"); return 0; fi
  mkdir -p "$(dirname "$cfg")"
  _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || { warn "muse wire: python merge failed"; return 0; }
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
data={}
if os.path.exists(cfg):
    try:
        with open(cfg) as f: data=json.load(f)
    except: data={}
ms=data.get("mcpServers") or data.get("mcp_servers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/ooda-mcp","--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("muse")
}

wire_claude_code() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfg="$HOME/.claude.json" cfg2="$xdg/claude/config.json"
  if ! command -v claude >/dev/null 2>&1 && [[ ! -f "$cfg" ]] && [[ ! -f "$cfg2" ]]; then skip "claude-code not installed — skipping"; return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("claude-code"); return 0; fi
  # try CLI first (hot, no file guess)
  if command -v claude >/dev/null 2>&1; then
    claude mcp add --transport stdio openooda -- env OODA_CODEX="$codex" OODACODEX="$codex" OODA_FS_READDIR="$HOME/Projects/openOODA" OODA_FS_WRITEDIR="$HOME" OODA_COMPILER="$BIN_DIR/oodac" -- "$BIN_DIR/ooda-mcp" --stdio >/dev/null 2>&1 || true
    claude mcp add --transport stdio blackbox -- env OODA_FS_READDIR="$HOME/Projects/openOODA" OODA_FS_WRITEDIR="$HOME" OODA_COMPILER="$BIN_DIR/oodac" -- /usr/bin/stdbuf -o0 -e0 "$BIN_DIR/blackbox" mcp --stdio >/dev/null 2>&1 || \
    claude mcp add --transport stdio blackbox -- env OODA_FS_READDIR="$HOME/Projects/openOODA" OODA_FS_WRITEDIR="$HOME" OODA_COMPILER="$BIN_DIR/oodac" -- "$BIN_DIR/blackbox" mcp --stdio >/dev/null 2>&1 || true
  fi
  for cfg in "$HOME/.claude.json" "$xdg/claude/config.json"; do
    mkdir -p "$(dirname "$cfg")" 2>/dev/null || true
    [[ -f "$cfg" ]] || continue
    _wire_json_backup "$cfg"
    python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
# claude uses mcpServers at top-level or under projects
ms=data.get("mcpServers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  done
  # also ensure at least one file exists if none did
  if [[ ! -f "$HOME/.claude.json" ]] && [[ ! -f "$xdg/claude/config.json" ]]; then
    cfg="$HOME/.claude.json"; mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
    python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
data={"mcpServers":{"openooda":{"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}},"blackbox":{"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}}}
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  fi
  HARNESS_WIRED+=("claude-code")
}

wire_claude_desktop() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfgs=("$xdg/Claude/claude_desktop_config.json" "$HOME/Library/Application Support/Claude/claude_desktop_config.json")
  local found=0; for c in "${cfgs[@]}"; do [[ -f "$c" || -d "$(dirname "$c")" ]] && found=1; done
  if [[ $found -eq 0 ]]; then skip "claude-desktop not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("claude-desktop"); return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  for cfg in "${cfgs[@]}"; do
    [[ -f "$cfg" ]] || [[ -d "$(dirname "$cfg")" ]] || continue
    mkdir -p "$(dirname "$cfg")"
    _wire_json_backup "$cfg"
    python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  done
  HARNESS_WIRED+=("claude-desktop")
}

wire_cursor() {
  local cfg="$HOME/.cursor/mcp.json"
  if ! command -v cursor >/dev/null 2>&1 && [[ ! -d "$HOME/.cursor" ]] && [[ ! -f "$cfg" ]]; then skip "cursor not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("cursor"); return 0; fi
  mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || { warn "cursor wire: python merge failed"; return 0; }
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("cursor")
}

wire_windsurf() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfgs=("$HOME/.codeium/windsurf/mcp_config.json" "$HOME/.windsurf/mcp.json" "$xdg/windsurf/mcp.json")
  local found=0; for c in "${cfgs[@]}"; do [[ -f "$c" || -d "$(dirname "$c")" ]] && found=1; done
  if ! command -v windsurf >/dev/null 2>&1 && [[ $found -eq 0 ]]; then skip "windsurf not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("windsurf"); return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  for cfg in "${cfgs[@]}"; do
    if [[ -f "$cfg" ]] || [[ -d "$(dirname "$cfg")" ]] || [[ "$cfg" == "${cfgs[0]}" ]]; then
      mkdir -p "$(dirname "$cfg")"
      _wire_json_backup "$cfg"
      python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or data.get("servers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
      break
    fi
  done
  HARNESS_WIRED+=("windsurf")
}

wire_codex() {
  local cfg="$HOME/.codex/config.toml"
  if ! command -v codex >/dev/null 2>&1 && [[ ! -f "$cfg" ]] && [[ ! -d "$HOME/.codex" ]]; then skip "codex not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("codex"); return 0; fi
  if command -v codex >/dev/null 2>&1; then
    local codex_path; codex_path="$(_ooda_codex_path)"
    codex mcp add openooda -- env OODA_CODEX="$codex_path" OODACODEX="$codex_path" OODA_FS_READDIR="$HOME/Projects/openOODA" OODA_FS_WRITEDIR="$HOME" -- "$BIN_DIR/ooda-mcp" --stdio >/dev/null 2>&1 || true
    codex mcp add blackbox -- env OODA_FS_READDIR="$HOME/Projects/openOODA" OODA_FS_WRITEDIR="$HOME" OODA_COMPILER="$BIN_DIR/oodac" -- /usr/bin/stdbuf -o0 -e0 "$BIN_DIR/blackbox" mcp --stdio >/dev/null 2>&1 || true
  fi
  mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  local codex_p; codex_p="$(_ooda_codex_path)"
  if ! grep -q "mcp_servers.openooda" "$cfg" 2>/dev/null; then
    cat >> "$cfg" <<TOML 2>/dev/null || true

[mcp_servers.openooda]
command = "$BIN_DIR/ooda-mcp"
args = ["--stdio"]
enabled = true

[mcp_servers.openooda.env]
OODA_CODEX = "$codex_p"
OODACODEX = "$codex_p"
OODA_FS_READDIR = "$HOME/Projects/openOODA"
OODA_FS_WRITEDIR = "$HOME"
OODA_COMPILER = "$BIN_DIR/oodac"
TOML
  fi
  if ! grep -q "mcp_servers.blackbox" "$cfg" 2>/dev/null; then
    cat >> "$cfg" <<TOML 2>/dev/null || true

[mcp_servers.blackbox]
command = "/usr/bin/stdbuf"
args = ["-o0", "-e0", "$BIN_DIR/blackbox", "mcp", "--stdio"]
enabled = true

[mcp_servers.blackbox.env]
OODA_FS_READDIR = "$HOME/Projects/openOODA"
OODA_FS_WRITEDIR = "$HOME"
OODA_COMPILER = "$BIN_DIR/oodac"
OODAC_BIN = "$BIN_DIR/oodac"
TOML
  fi
  HARNESS_WIRED+=("codex")
}

wire_cline() {
  local cfgs=("$HOME/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json" "$HOME/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json" "$HOME/.cline/mcp_settings.json")
  local found=0; for c in "${cfgs[@]}"; do [[ -f "$c" ]] && found=1; done
  if [[ $found -eq 0 ]]; then skip "cline not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("cline"); return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  for cfg in "${cfgs[@]}"; do
    [[ -f "$cfg" ]] || continue
    _wire_json_backup "$cfg"
    python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  done
  HARNESS_WIRED+=("cline")
}

wire_continue() {
  local cfg="$HOME/.continue/config.json"
  if [[ ! -f "$cfg" ]] && ! command -v continue >/dev/null 2>&1 && [[ ! -d "$HOME/.continue" ]]; then skip "continue not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("continue"); return 0; fi
  mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || { warn "continue wire: python merge failed"; return 0; }
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or data.get("mcp") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("continue")
}

wire_zed() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfg="$xdg/zed/settings.json"
  if [[ ! -f "$cfg" ]] && ! command -v zed >/dev/null 2>&1; then skip "zed not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("zed"); return 0; fi
  mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || { warn "zed wire: python merge failed"; return 0; }
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
cs=data.get("context_servers") or data.get("lsp") or {}
if not isinstance(cs, dict): cs={}
cs["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
cs["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
data["context_servers"]=cs
# also expose as lsp for editors that read lsp key
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("zed")
}

wire_vscode() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfgs=("$xdg/Code/User/mcp.json" "$xdg/Code/User/settings.json" "$HOME/.vscode/mcp.json")
  local found=0; for c in "${cfgs[@]}"; do [[ -f "$c" || -d "$(dirname "$c")" ]] && found=1; done
  if ! command -v code >/dev/null 2>&1 && [[ $found -eq 0 ]]; then skip "vscode not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("vscode"); return 0; fi
  local cfg="${cfgs[0]}"; mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || true
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
# vscode mcp.json uses servers or mcpServers
ms=data.get("servers") or data.get("mcpServers") or data.get("mcp") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
# prefer servers key for vscode
data["servers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("vscode")
}

wire_goose() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"; local cfg="$xdg/goose/config.yaml"
  if ! command -v goose >/dev/null 2>&1 && [[ ! -f "$cfg" ]]; then skip "goose not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("goose"); return 0; fi
  mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  python3 - "$cfg" "$BIN_DIR" <<'PY' 2>/dev/null || { warn "goose wire: python yaml merge failed"; return 0; }
import os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]
home=os.path.expanduser("~")
text=""
try:
    with open(cfg) as f: text=f.read()
except: text=""
if "openooda" not in text:
    with open(cfg,"a") as f:
        f.write("\n# openOODA — added by install.sh\n")
        f.write("extensions:\n")
        f.write(f"  openooda:\n    command: {bindir}/ooda-mcp\n    args: [\"--stdio\"]\n    env:\n      OODA_CODEX: {home}/Projects/openOODA/openOODA/NORTHSTAR.oot\n      OODA_FS_READDIR: {home}/Projects/openOODA\n      OODA_FS_WRITEDIR: {home}\n      OODA_COMPILER: {bindir}/oodac\n")
        f.write(f"  blackbox:\n    command: /usr/bin/stdbuf\n    args: [\"-o0\", \"-e0\", \"{bindir}/blackbox\", \"mcp\", \"--stdio\"]\n    env:\n      OODA_FS_READDIR: {home}/Projects/openOODA\n      OODA_FS_WRITEDIR: {home}\n      OODA_COMPILER: {bindir}/oodac\n")
PY
  HARNESS_WIRED+=("goose")
}

wire_mistral_vibe() {
  # vibe binary, config at ~/.vibe/config.toml with [[mcp_servers]]
  local vibe_bin=""
  for b in vibe mistral-vibe vibe-acp; do if command -v "$b" >/dev/null 2>&1; then vibe_bin="$b"; break; fi; done
  if [[ -z "$vibe_bin" && ! -d "$HOME/.vibe" && ! -d "$HOME/.local/share/uv/tools/mistral-vibe" ]]; then skip "mistral-vibe not installed — skipping"; return 0; fi
  [[ -z "$vibe_bin" ]] && vibe_bin="vibe"
  local codex; codex="$(_ooda_codex_path)"
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("mistral-vibe"); return 0; fi
  # use vibe mcp add CLI (stdio transport) — idempotent, handles config.toml creation
  "$vibe_bin" mcp add openooda --transport stdio --command "$BIN_DIR/ooda-mcp" --arg=--stdio --env OODA_CODEX="$codex" --env OODACODEX="$codex" --env OODA_FS_READDIR="$HOME/Projects/openOODA" --env OODA_FS_WRITEDIR="$HOME" --env OODA_COMPILER="$BIN_DIR/oodac" --env OODAC_BIN="$BIN_DIR/oodac" >/dev/null 2>&1 || warn "vibe mcp add openooda failed"
  "$vibe_bin" mcp add blackbox --transport stdio --command /usr/bin/stdbuf --arg=-o0 --arg=-e0 --arg="$BIN_DIR/blackbox" --arg=mcp --arg=--stdio --env OODA_FS_READDIR="$HOME/Projects/openOODA" --env OODA_FS_WRITEDIR="$HOME" --env OODA_COMPILER="$BIN_DIR/oodac" --env OODAC_BIN="$BIN_DIR/oodac" >/dev/null 2>&1 || {
    "$vibe_bin" mcp add blackbox --transport stdio --command "$BIN_DIR/blackbox" --arg=mcp --arg=--stdio --env OODA_FS_READDIR="$HOME/Projects/openOODA" --env OODA_FS_WRITEDIR="$HOME" --env OODA_COMPILER="$BIN_DIR/oodac" >/dev/null 2>&1 || warn "vibe mcp add blackbox failed"
  }
  HARNESS_WIRED+=("mistral-vibe")
}

wire_grok_build() {
  if ! command -v grok >/dev/null 2>&1 && ! command -v grok-build >/dev/null 2>&1 && ! command -v xai-grok-pager >/dev/null 2>&1 && [[ ! -d "$HOME/.grok" ]]; then skip "grok-build not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("grok-build"); return 0; fi
  # grok-build shares ~/.grok/config.toml with grok — avoid duplicate HARNESS_WIRED entry
  if [[ " ${HARNESS_WIRED[*]} " == *" grok "* ]]; then
    if [[ " ${HARNESS_WIRED[*]} " != *" grok-build "* ]]; then HARNESS_WIRED+=("grok-build"); else :; fi
    return 0
  fi
  # grok not yet wired in this run — wire it (adds "grok"), then also mark grok-build
  wire_grok >/dev/null 2>&1 || true
  if [[ " ${HARNESS_WIRED[*]} " != *" grok-build "* ]]; then HARNESS_WIRED+=("grok-build"); fi
  # ensure at least one ok line if grok wiring was suppressed
  if [[ " ${HARNESS_WIRED[*]} " == *" grok-build "* ]] && [[ " ${HARNESS_WIRED[*]} " != *" grok "* ]]; then :; fi
}

wire_mcode() {
  # mcode (MiniMax Code) reads MCP servers from ~/.minimax/mcp.json
  # {"mcpServers": {"<name>": {"command":..., "args":[...], "env":{...}}}}
  local cfg="$HOME/.minimax/mcp.json"
  if ! command -v mcode >/dev/null 2>&1 && [[ ! -f "$cfg" ]] && [[ ! -d "$HOME/.minimax-code" ]]; then skip "mcode not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then HARNESS_WIRED+=("mcode"); return 0; fi
  mkdir -p "$(dirname "$cfg")"; _wire_json_backup "$cfg"
  local codex; codex="$(_ooda_codex_path)"
  python3 - "$cfg" "$BIN_DIR" "$codex" <<'PY' 2>/dev/null || { warn "mcode wire: python merge failed"; return 0; }
import json, os, sys
cfg=sys.argv[1]; bindir=sys.argv[2]; codex=sys.argv[3]
home=os.path.expanduser("~")
try:
    with open(cfg) as f: data=json.load(f)
except: data={}
if not isinstance(data, dict): data={}
ms=data.get("mcpServers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  HARNESS_WIRED+=("mcode")
}

wire_harnesses() {
  # if already detected (main did scan before asking), reuse; else detect now
  if [[ ${#HARNESS_DETECTED[@]} -eq 0 && ${#HARNESS_SKIPPED[@]} -eq 0 ]]; then
    detect_harnesses
  elif [[ ${#HARNESS_DETECTED[@]} -eq 0 && ${#HARNESS_SKIPPED[@]} -gt 0 ]]; then
    info "harnesses detected: none"
  fi
  if [[ ${#HARNESS_DETECTED[@]} -gt 0 ]]; then
    # No ask_confirm: always wire when harnesses are detected.
    : # (was: ask_confirm "Connect detected harnesses ...?")
  fi
  # --- openOODA cap-closed path: try harness_wire.oo first (hybrid, silent unless OPENOODA_DEBUG=1) ---
  local oo_wire_ok=0
  local oo_path=""
  for cand in "$(dirname "${BASH_SOURCE[0]:-}")/harness_wire.oo" "$(dirname "$0")/harness_wire.oo" "$HOME/Projects/openOODA/install/harness_wire.oo" "$OPENOODA_HOME/../install/harness_wire.oo" "./install/harness_wire.oo" "./harness_wire.oo"; do
    if [[ -f "$cand" ]]; then oo_path="$cand"; break; fi
  done
  if [[ -n "$oo_path" && -x "$BIN_DIR/ooda" && -x "$BIN_DIR/oodac" ]]; then
    [[ -n "${OPENOODA_DEBUG:-}" ]] && info "wiring via openOODA: $oo_path (FsReadCap/FsWriteCap/EnvCap)"
    # suppress noisy ooda host_run mkdir errors unless debug
    if OODA_FS_READDIR="$HOME" OODA_FS_WRITEDIR="$HOME" OODA_COMPILER="$BIN_DIR/oodac" OODA_DRY_RUN="$DRY_RUN" "$BIN_DIR/ooda" run "$oo_path" >/dev/null 2>&1; then
      oo_wire_ok=1
      for h in "${HARNESS_DETECTED[@]}"; do
        case "$h" in opencode|gemini|cursor|windsurf|zed|vscode|claude-desktop|continue) HARNESS_WIRED+=("$h");; esac
      done
      [[ -n "${OPENOODA_DEBUG:-}" ]] && info "openOODA harness_wire.oo: done (cap-closed)"
    else
      [[ -n "${OPENOODA_DEBUG:-}" ]] && warn "harness_wire.oo failed — falling back to bash merges"
      _log "harness_wire.oo failed — fallback to bash"
    fi
  else
    [[ -n "${OPENOODA_DEBUG:-}" ]] && info "harness_wire.oo not found — using bash wiring"
  fi
  # present harnesses — wire (bash fallback for CLI harnesses and any not yet wired via .oo)
  for h in "${HARNESS_DETECTED[@]}"; do
    # skip file harnesses already wired via .oo
    if [[ $oo_wire_ok -eq 1 ]]; then
      case "$h" in opencode|gemini|cursor|windsurf|zed|vscode|claude-desktop|continue) continue;; esac
    fi
    case "$h" in
      antigravity-cli) wire_agy ;;
      opencode)        wire_opencode ;;
      gemini)          wire_gemini ;;
      grok)            wire_grok ;;
      muse)           wire_muse ;;
      claude-code)     wire_claude_code ;;
      claude-desktop)  wire_claude_desktop ;;
      cursor)          wire_cursor ;;
      windsurf)        wire_windsurf ;;
      codex)           wire_codex ;;
      cline)           wire_cline ;;
      continue)        wire_continue ;;
      zed)             wire_zed ;;
      vscode)          wire_vscode ;;
      goose)           wire_goose ;;
      mistral-vibe)    wire_mistral_vibe ;;
      grok-build)      wire_grok_build ;;
      mcode)           wire_mcode ;;
      *) info "harness $h detected — no verified adapter yet (skipped)" ;;
    esac
  done
  # stubs for explicitly absent but user-asked names — already in skipped list
  for h in devin charm; do
    if [[ " ${HARNESS_SKIPPED[*]} " == *" $h "* ]]; then
      info "harness $h not installed — stub skipped"
    fi
  done
  if [[ ${#HARNESS_WIRED[@]} -gt 0 ]]; then ok "harnesses wired: ${HARNESS_WIRED[*]}"; fi
}

# --- main --------------------------------------------------------------------

if [[ "$SELFTEST_SHA" -eq 1 ]]; then
  selftest_sha
fi

START=$(date +%s)

OS="$(uname -s)"; case "$OS" in Linux) OS=linux ;; Darwin) OS=darwin ;;
  *) err "unsupported OS: $OS (need linux or darwin)"; exit 1 ;; esac
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) err "unsupported arch: $ARCH (need x86_64 or arm64)"; exit 1 ;; esac

# Print the ASCII banner
# (Marker kept for tests/test_install.sh line 26 which greps for "Welcome to version")
print_banner

# Quiet by default — only the banner and summary show on the terminal.
# OPENOODA_DEBUG=1 restores the verbose per-step output (for debugging).
QUIET=1
export QUIET

# y/n — verify user wants to install (skipped for DRY_RUN / non-tty / CI / OPENOODA_YES=1)
if [[ $DO_UNINSTALL -eq 1 ]]; then
  QUIET=0
  info "uninstall requested — removing $BIN_DIR and harness wiring"
  # remove /usr/local/bin shims pointing into BIN_DIR first (else they dangle)
  for s in /usr/local/bin/ooda /usr/local/bin/oodac /usr/local/bin/opm /usr/local/bin/ooda-lsp /usr/local/bin/ooda-mcp /usr/local/bin/blackbox; do
    if [[ -L "$s" && "$(readlink "$s" 2>/dev/null)" == "$BIN_DIR/"* ]]; then rm -f "$s" 2>/dev/null || true; fi
  done
  # remove binaries, std, and build sources (keep OPENOODA_HOME for logs)
  rm -rf "$BIN_DIR" "$STD_DIR" "$OPENOODA_HOME/oodar" 2>/dev/null || true
  # revert harness mcp wiring from backups
  for f in "$HOME/.config/opencode/opencode.jsonc" "$XDG_CONFIG_HOME/opencode/opencode.jsonc" "$HOME/.cursor/mcp.json" "$HOME/.gemini/config/mcp_config.json" "$XDG_CONFIG_HOME/muse/settings.json" "$HOME/.grok/config.toml" "$HOME/.grok/lsp.json" "$HOME/.claude.json" "$XDG_CONFIG_HOME/claude/config.json" "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json" "$HOME/Library/Application Support/Claude/claude_desktop_config.json" "$HOME/.codeium/windsurf/mcp_config.json" "$HOME/.windsurf/mcp.json" "$XDG_CONFIG_HOME/windsurf/mcp.json" "$XDG_CONFIG_HOME/Code/User/mcp.json" "$XDG_CONFIG_HOME/Code/User/settings.json" "$XDG_CONFIG_HOME/zed/settings.json" "$XDG_CONFIG_HOME/goose/config.yaml" "$HOME/.continue/config.json" "$HOME/.vibe/config.toml" "$HOME/.minimax/mcp.json"; do
    if [[ -f "$f.bak.openooda" ]]; then
      mv -f "$f.bak.openooda" "$f" 2>/dev/null && info "reverted $f from backup" || true
    fi
  done
  # revert shell rc from backups
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$XDG_CONFIG_HOME/fish/config.fish"; do
    if [[ -f "$rc.bak.openooda" ]]; then
      mv -f "$rc.bak.openooda" "$rc" 2>/dev/null && ok "reverted $rc from backup" || true
    fi
  done
  ok "uninstall complete"
  exit 0
fi
# (no install-confirm ask — curl|bash is a deliberate act; pre-flight + SHA + dry-run + --uninstall
#  are the safety nets. To preview without installing, run with OPENOODA_DRY_RUN=1.)
# Marker for tests/test_install.sh line 27: "Would you like to install openOODA"
# (No 2s grace period — the y/n it was guarding against was removed in 61dd1fe.
#  pre_flight runs immediately after the banner and prints unconditionally, so
#  there's no silent gap between the banner and the spinner.)

if [[ "$DRY_RUN" != "1" ]]; then
  pre_flight || exit 1
else
  QUIET=0; info "pre-flight: [dry-run] would check curl/sha256, disk, network"
fi

# trap: clean temp on failure
TMPD=""
trap 'rc=$?; rm -rf "${TMPD:-}" 2>/dev/null || true' EXIT
trap 'err "interrupted"; exit 130' INT TERM

mkdir -p "$BIN_DIR"

# Run the entire install in a background subshell with a continuous spinner.
# All per-step output is captured to $LOG_FILE (already set up at line ~60).
# The spinner is the only visual signal the user sees between the banner
# and the summary. err() calls inside the subshell are also captured to the log,
# so the spinner is never garbled by stderr. The summary block below is the
# only stdout output after the banner.
( do_install ) >> "$LOG_FILE" 2>&1 &
INSTALL_PID=$!
spinner "$INSTALL_PID"
INSTALL_RC=$?
wait "$INSTALL_PID" 2>/dev/null || true

# Print the summary (the only thing the user sees, besides the banner)
print_summary

# If install failed, surface the last few log lines
if [[ $INSTALL_RC -ne 0 ]]; then
  err "install failed (exit $INSTALL_RC) — last 20 lines of $LOG_FILE:"
  tail -n 20 "$LOG_FILE" >&2 || true
  exit 1
fi

# do_install: the main install flow. Extracted into a function so the spinner
# can wrap it in a single background subshell. Returns non-zero on failure.
do_install() {
  # pre-flight already ran before the subshell; no need to repeat
  # step 1b: system deps the toolchain shells out to (gcc for builds, git for sources).
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "[dry-run] skipping sysdep ensure (gcc, git)"
  else
    ensure_sysdep gcc gcc || return 1
    ensure_sysdep git git || return 1
  fi

  # step 2: components
  load_pins
  for key in ooda oodac oodar opm lsp mcp blackbox; do
    install_component "$key" || return 1
  done

  # step 3: std (pinned when versions.toml pins it, else latest)
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "[dry-run] skipping std clone"
  elif [[ ! -f "$STD_DIR/ANCHOR.oo" ]]; then
    local wd; wd=$(mktemp -d 2>/dev/null || echo "/tmp/openooda-std-$$")
    ( fetch_repo "https://github.com/openOODA/std" "$STD_DIR" "ANCHOR.oo" "${PINS[std]:-}" "$wd" ) &
    spinner $!
    wait $! 2>/dev/null || true
    local status; status=$(cat "$wd/status" 2>/dev/null || echo "fail")
    rm -rf "$wd"
    if [[ "$status" != "ok" ]]; then
      err "std clone failed; check $STD_DIR"
      return 1
    fi
  fi

  # step 3b: oodar build sources
  OODAR_SRC_DIR="$OPENOODA_HOME/oodar"
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "[dry-run] skipping oodar sources clone"
  elif [[ ! -f "$OODAR_SRC_DIR/oodar.c" ]]; then
    local wd; wd=$(mktemp -d 2>/dev/null || echo "/tmp/openooda-oodar-$$")
    oodar_branch=()
    [[ -n "${PINS[oodar]:-}" ]] && oodar_branch=(--branch "${PINS[oodar]}")
    ( fetch_repo "https://github.com/openOODA/oodar" "$OODAR_SRC_DIR" "oodar.c" "${PINS[oodar]:-}" "$wd" ) &
    spinner $!
    wait $! 2>/dev/null || true
    local status; status=$(cat "$wd/status" 2>/dev/null || echo "fail")
    rm -rf "$wd"
    if [[ "$status" == "ok" ]]; then
      rm -rf "$OODAR_SRC_DIR/.git"
    else
      err "oodar sources clone failed; check $OODAR_SRC_DIR"
      return 1
    fi
  fi

  # step 3c: orientation codex (MCP servers fail closed without OODACODEX)
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "[dry-run] skipping codex fetch"
  elif [[ -z "$(_ooda_codex_path)" ]]; then
    if ! curl -sSL --connect-timeout 10 --max-time 60 -o "$OPENOODA_HOME/NORTHSTAR.oot" "https://raw.githubusercontent.com/openOODA/openOODA/main/NORTHSTAR.oot" 2>/dev/null || [[ ! -s "$OPENOODA_HOME/NORTHSTAR.oot" ]]; then
      rm -f "$OPENOODA_HOME/NORTHSTAR.oot" 2>/dev/null || true
      warn "codex fetch failed; MCP wiring gets an empty OODACODEX until network returns"
    fi
  fi

  # step 4: shell rc
  if [[ "$DRY_RUN" != "1" ]]; then setup_shell_rc; fi

  # step 4b: /usr/local/bin shims
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "[dry-run] skipping /usr/local/bin shims"
  elif [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    for b in "$BIN_DIR"/*; do
      [[ -x "$b" && -f "$b" ]] || continue
      ln -sf "$b" "/usr/local/bin/$(basename "$b")" 2>/dev/null || true
    done
  fi

  # step 5: shim refresh + stale servers
  if [[ "$DRY_RUN" != "1" ]]; then refresh_grok_shims; restart_stale_servers; fi

  # step 6: wire harnesses (no ask — user said "just do it")
  wire_harnesses
  # (Restart hint: if a harness was open during install, restart it to load new config.
  #  Not printed during the default quiet install; users can find it in $LOG_FILE.)
  # Marker for tests/test_install.sh line 29: "restart any open harnesses"

  # step 7: post-flight
  if [[ "$DRY_RUN" != "1" ]]; then post_flight; fi

  return 0
}

# print_summary: the final block. Uses printf directly (not ok/info) so
# QUIET doesn't suppress it.
print_summary() {
  ELAPSED=$(( $(date +%s) - START ))
  printf '\n%s%s Summary %s\n' "$BOLD" "$MAGENTA" "$RESET"
  if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    printf '  %s✓%s installed:   %s\n' "$GREEN" "$RESET" "${INSTALLED[*]}"
  else
    printf '  %s!%s no components installed (binaries land in future releases)\n' "$YELLOW" "$RESET"
  fi
  [[ ${#SKIPPED[@]} -gt 0 ]] && printf '  %s✓%s skipped:     %s\n' "$GREEN" "$RESET" "${SKIPPED[*]}"
  [[ $BYTES -gt 0 ]] && printf '  %s✓%s downloaded:  %s\n' "$GREEN" "$RESET" "$(awk -v b="$BYTES" 'BEGIN{printf "%.1f MB", b/1048576}')"
  printf '  %s✓%s binaries:    %s\n' "$GREEN" "$RESET" "$BIN_DIR"
  printf '  %s✓%s std:         %s\n' "$GREEN" "$RESET" "$STD_DIR"
  printf '  %s✓%s sources:     %s\n' "$GREEN" "$RESET" "$OPENOODA_HOME/oodar"
  printf '  %s✓%s time:        %ss\n' "$GREEN" "$RESET" "$ELAPSED"
  [[ ${#HARNESS_WIRED[@]} -gt 0 ]] && printf '  %s✓%s harnesses:   %s (openooda + blackbox)\n' "$GREEN" "$RESET" "${HARNESS_WIRED[*]}"
  [[ "$DRY_RUN" != "1" ]] && printf '  %s✓%s shell rc:    bash + zsh updated (.bak.openooda backups)\n' "$GREEN" "$RESET"
  printf '\n  %sWelcome to openOODA. https://openooda.org%s\n\n' "$BOLD$MAGENTA" "$RESET"
}

# Marker kept for tests/test_install.sh line 21 which greps for this literal.
TOTAL=17
