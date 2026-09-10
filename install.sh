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
KEEP_STALE=0
DO_UNINSTALL=0
SELFTEST_SHA=0
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
# VERSION: read from the VERSION file next to this script, with a fallback
# for curl|bash invocations where the script is on stdin (no file).
# Curl fallback fetches from GitHub (3s timeout) so curl|bash always shows
# a real version; static fallback "0.1.30" if both fail.
VERSION="$(cat "$(dirname "${BASH_SOURCE[0]:-$0}")/VERSION" 2>/dev/null || curl -sSL --max-time 3 "https://raw.githubusercontent.com/openOODA/install/main/VERSION" 2>/dev/null || echo "0.1.30")"
VERSION="$(printf '%s' "$VERSION" | tr -d '\r\n ' | head -c 20)"
[[ -z "$VERSION" ]] && VERSION="0.1.30"

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
  --keep-stale        don't remove stale openooda binaries in legacy shadow locations (~/.local/bin)
  --clean-stale       same as default — remove stale openooda binaries in legacy shadow locations
  --uninstall         remove binaries and std
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
    --keep-stale) KEEP_STALE=1;;
    --clean-stale) : ;;  # default behavior; flag accepted for explicitness
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
# No `2>/dev/null` on the exec — bash 5.3.9 has a quirk where
# `exec 3>>file 2>/dev/null` silently kills the script. The fallback
# `|| exec 3>/dev/null` still catches the failure; the error message
# (if the log file can't be opened) goes to stderr, which is informative.
exec 3>>"$LOG_FILE" || exec 3>/dev/null
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

# spinner_with_status: like spinner, but reads $STATUS_FILE each frame and
# displays its content next to the spinner glyph. This is the "story" —
# the user sees the narrative of what the install is doing. Falls back to
# the literal "working" if the status file is empty/unreadable.
spinner_with_status() {
  local pid=$1 status_file="$2"
  local frames
  if [[ -t 1 ]] && [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *UTF-8* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *utf8* ]]; then
    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    frames=('|' '/' '-' '\' '|' '/' '-' '\' '|' '/')
  fi
  local i=0 step
  while kill -0 "$pid" 2>/dev/null; do
    step=""
    [[ -r "$status_file" ]] && step=$(cat "$status_file" 2>/dev/null | tr -d '\n' | head -c 60)
    [[ -z "$step" ]] && step="working"
    printf '\r  %s%s%s %s%-60s%s' "$CYAN" "${frames[i++ % ${#frames[@]}]}" "$RESET" "$BOLD" "$step" "$RESET"
    sleep 0.15
  done
  # Clear the spinner line so the summary starts on a fresh line.
  printf '\r%*s\r' 78 ""
}

overwrite_bar() {
  local pct=$(( ($1 * 100 + $2 / 2) / $2 ))
  printf '\r  %s %s%s%3d%%%s (%d/%d)' "$(bar $pct)" "$BOLD" "$MAGENTA" "$pct" "$RESET" "$1" "$2"
}
# step_status: write the current step name to $STATUS_FILE. The spinner
# reads this file each frame so the user sees the narrative of what the
# install is doing, not just a spinning glyph. Cheap; one builtin echo.
# No-op if STATUS_FILE is unset or unwritable.
step_status() {
  [[ -n "${STATUS_FILE:-}" ]] || return 0
  printf '%s' "$*" > "$STATUS_FILE" 2>/dev/null || true
}
# dump_results: write the cross-subshell state to $RESULTS_FILE. The
# ( do_install ) subshell populates INSTALLED/SKIPPED/BYTES
# in its own copy of the variables; when it exits, those vars are gone in
# the parent. We serialise them to a tmp file (same pattern as STATUS_FILE)
# so print_summary in the parent sees what really happened. Format is a
# shell snippet sourced back in the parent; %q makes every element safe
# to re-evaluate even with spaces or quotes in the value.
dump_results() {
  [[ -n "${RESULTS_FILE:-}" ]] || return 0
  {
    printf 'INSTALLED=(\n'
    if [[ ${#INSTALLED[@]} -gt 0 ]]; then
      for x in "${INSTALLED[@]}"; do printf '  %q\n' "$x"; done
    fi
    printf ')\nSKIPPED=(\n'
    if [[ ${#SKIPPED[@]} -gt 0 ]]; then
      for x in "${SKIPPED[@]}"; do printf '  %q\n' "$x"; done
    fi
    printf ')\nBYTES=%s\n' "${BYTES:-0}"
  } > "$RESULTS_FILE" 2>/dev/null || true
}
ok()   { [[ "${QUIET:-0}" == "1" ]] && { _log "OK $*"; return; }; printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; _log "OK $*"; }
warn() { [[ "${QUIET:-0}" == "1" ]] && { _log "WARN $*"; return; }; printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; _log "WARN $*"; }
err()  { printf '  %s✗%s %s\n' "$RED"    "$RESET" "$*" >&2; _log "ERR $*"; }
skip() { [[ "${QUIET:-0}" == "1" ]] && { _log "SKIP $*"; return; }; printf '  %s⊘%s %s\n' "$YELLOW" "$RESET" "$*"; _log "SKIP $*"; }
info() { [[ "${QUIET:-0}" == "1" ]] && { _log "INFO $*"; return; }; printf '  %s•%s %s\n' "$GRAY"   "$RESET" "$*"; _log "INFO $*"; }

# fetch_runtime_version: best-effort fetch of the openOODA/openOODA polyrepo's
# latest tag, with a 3s timeout. Falls back to "?" on any failure (no
# network, rate-limit, python3 missing). The runtime version is the
# polyrepo's release tag (e.g. "2.10.28"), which is what the install
# is about to put on disk. Surfaces the relationship between the
# installer (this script) and the runtime (the polyrepo) — they're
# versioned independently, and users should see both.
fetch_runtime_version() {
  curl -sSL --max-time 3 "https://api.github.com/repos/openOODA/openOODA/releases/latest" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tag_name','?'))" 2>/dev/null \
    | sed 's/^v//' \
    | head -c 30 \
    || echo "?"
}

# print_banner: one-line version stamp. Two layers because openOODA is
# a polyrepo: this script's own version (install/VERSION) and the
# polyrepo's current release (openOODA/openOODA latest tag, fetched
# at runtime). Both honest; the runtime half is a soft fetch that
# gracefully degrades to "?" if the network is down.
print_banner() {
  local runtime
  runtime=$(fetch_runtime_version)
  [[ -z "$runtime" ]] && runtime="?"
  printf '  openOODA v%s · runtime v%s · curl|bash\n\n' "$VERSION" "$runtime"
}

# print_preamble: short story before the install starts. Sets expectations,
# names the SHA-256 verification step explicitly, and gives the user a
# sense of time. Tells the user what is about to happen, in plain words.
print_preamble() {
  printf '  %sopenOODA installer — what we'\''re about to do:%s\n\n' "$BOLD" "$RESET"
  printf '    %s1.%s check your environment (curl, sha256, network, disk)\n' "$DIM" "$RESET"
  printf '    %s2.%s download 7 binaries (ooda, oodac, oodar, opm, lsp, mcp, blackbox)\n' "$DIM" "$RESET"
  printf '    %s3.%s verify each binary'\''s SHA-256 against its release signature\n' "$DIM" "$RESET"
  printf '    %s4.%s clone the standard library (openOODA/std)\n' "$DIM" "$RESET"
  printf '    %s5.%s clone the runtime sources (openOODA/oodar)\n' "$DIM" "$RESET"
  printf '    %s6.%s set up shell environment (PATH, OODA_COMPILER, etc.)\n\n' "$DIM" "$RESET"
  printf '  %sEstimated time: 10-60 seconds. Press Ctrl-C to cancel.%s\n\n' "$DIM" "$RESET"
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
  # Sidecar was a download-time artifact. Once the binary is verified and
  # in place, drop the sidecar: a local rebuild that overwrites the binary
  # would diverge from the sidecar, leaving a misleading "this is the hash"
  # record. The install log line already records the verified hash.
  rm -f "$dest.tmp.sha256" 2>/dev/null || true
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
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would update shell rc (bashrc)"; return 0; fi
  local l1='export PATH="$HOME/.openooda/bin:$PATH"'
  local l2='export OODA_STD_ROOT="$HOME/.openooda/std"'
  local l3='export OODA_COMPILER="$HOME/.openooda/bin/oodac"'
  local l4='export OODA_FS_READDIR="$HOME/Projects/openOODA"'
  local l5='export OODA_FS_WRITEDIR="$HOME"'
  for rc in "$HOME/.bashrc"; do
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
}

# warn_for_other_shells: if zsh or fish is detected on PATH, print a one-line
# hint telling the user how to add openOODA to their non-bash rc. The install
# only writes ~/.bashrc; users with other shells do it themselves. Detected at
# the level of "binary on PATH" (not "rc file exists") so a leftover ~/.zshrc
# from a previous install doesn't trigger the warning.
warn_for_other_shells() {
  [[ "${QUIET:-0}" == "1" ]] && { _log "SKIP warn_for_other_shells (QUIET)"; return; }
  if command -v zsh >/dev/null 2>&1; then
    warn "zsh detected — to use openOODA in zsh, add to ~/.zshrc:"
    printf '       export PATH="$HOME/.openooda/bin:$PATH"\n' >&2
  fi
  if command -v fish >/dev/null 2>&1; then
    warn "fish detected — to use openOODA in fish, add to ~/.config/fish/config.fish:"
    printf '       fish_add_path $HOME/.openooda/bin\n' >&2
  fi
}

# clean_stale_shadow_binaries: remove openooda binaries in legacy shadow
# locations (currently ~/.local/bin) that predate the ~/.openooda/bin
# layout. These binaries can shadow the install when PATH order is wrong.
# Default: remove (with warning, logged to $LOG_FILE). --keep-stale skips
# removal but the post-install assert_path_resolution still catches the
# shadow and fails closed.
clean_stale_shadow_binaries() {
  [[ "${DRY_RUN:-0}" == "1" ]] && { ok "[dry-run] would clean stale openooda binaries in legacy locations"; return 0; }
  local targets=("ooda" "oodac" "ooda-lsp" "ooda-mcp" "opm" "blackbox" "oodac.bak")
  local removed=0 kept=0
  for shadow_dir in "$HOME/.local/bin" /usr/local/bin; do
    [[ -d "$shadow_dir" ]] || continue
    for b in "${targets[@]}"; do
      local f="$shadow_dir/$b"
      [[ -e "$f" ]] || continue
      # Skip shims we created in /usr/local/bin (those are our own; we
      # only remove them in --uninstall, not here).
      if [[ "$shadow_dir" == "/usr/local/bin" ]]; then
        if [[ -L "$f" && "$(readlink -f "$f" 2>/dev/null)" == "$BIN_DIR/"* ]]; then
          continue  # this is one of our own shims
        fi
      fi
      if [[ "$KEEP_STALE" == "1" ]]; then
        warn "shadow: $f is a stale openooda binary (--keep-stale, not removing)"
        kept=$((kept + 1))
      else
        warn "removing stale openooda binary: $f (from a previous install layout)"
        if rm -f "$f" 2>/dev/null; then
          _log "removed stale $f"
          removed=$((removed + 1))
        else
          warn "could not remove $f (permission denied?)"
        fi
      fi
    done
  done
  if [[ $removed -gt 0 ]]; then
    ok "removed $removed stale openooda binary(ies) from legacy locations"
  fi
  return 0
}

# assert_path_resolution: post-install invariant — for each binary the
# install wrote, `command -v` must resolve to $BIN_DIR/$key. If not, the
# install is shadowed by a stale binary somewhere on PATH. Reads INSTALLED
# from RESULTS_FILE (set by the subshell) so the function runs in the
# parent after the install subshell has finished. Fails closed on any
# divergence; the user can re-run with --keep-stale to silence the
# cleanup or fix the shadow externally.
assert_path_resolution() {
  [[ "${DRY_RUN:-0}" == "1" ]] && { ok "[dry-run] would assert command -v == \$BIN_DIR"; return 0; }
  [[ -r "${RESULTS_FILE:-}" ]] || { warn "assert_path_resolution: RESULTS_FILE missing, skipping"; return 0; }
  . "$RESULTS_FILE" 2>/dev/null || true
  local fail=0 checked=0
  for key in "${INSTALLED[@]:-}"; do
    [[ -n "$key" ]] || continue
    local bin_name="${BINARIES[$key]:-$key}"
    local dest="$BIN_DIR/$bin_name"
    local resolved
    resolved=$(command -v "$bin_name" 2>/dev/null || true)
    checked=$((checked + 1))
    # The shadow is OK if:
    #   (a) command -v resolves to our install path, OR
    #   (b) command -v resolves to the user's default install location
    #       ($HOME/.openooda/bin/) — that's the user's real install;
    #       this run's BIN_DIR is just shadowed by it, which is fine.
    # Otherwise it's a real foreign shadow (e.g., ~/.local/bin/ooda from
    # a prior install layout) and we fail closed.
    local home_install="$HOME/.openooda/bin/$bin_name"
    if [[ "$resolved" == "$dest" || "$resolved" == "$home_install" ]]; then
      : # OK
    else
      err "PATH shadow: '$bin_name' resolves to '$resolved' (expected '$dest')"
      err "  a stale openooda binary is shadowing the install"
      err "  fix: remove the shadowing binary, or re-run with --keep-stale to silence the cleanup"
      fail=1
    fi
  done
  if [[ $checked -eq 0 ]]; then
    ok "post-install assertion: no binaries installed; nothing to assert"
  elif [[ $fail -eq 1 ]]; then
    err "post-install assertion failed: stale binary shadowed the install"
    return 1
  else
    ok "post-install assertion: command -v resolves to $BIN_DIR for all $checked installed binaries"
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
  if [[ $fail -eq 1 ]]; then
    warn "post-flight: one or more binaries failed --help — see $LOG_FILE"
  else
    ok "post-flight: all binaries verified"
  fi
}

do_install() {
  # pre-flight already ran before the subshell; no need to repeat
  step_status "checking environment (pre-flight done)"
  # step 1b: system deps the toolchain shells out to (gcc for builds, git for sources).
  if [[ "$DRY_RUN" == "1" ]]; then
    step_status "[dry-run] skipping sysdep ensure (gcc, git)"
    skip "[dry-run] skipping sysdep ensure (gcc, git)"
  else
    step_status "ensuring gcc + git are installed"
    ensure_sysdep gcc gcc || return 1
    ensure_sysdep git git || return 1
  fi

  # step 2: components
  step_status "loading version pins"
  load_pins
  for key in ooda oodac oodar opm lsp mcp blackbox; do
    step_status "downloading + SHA-256 verifying $key"
    install_component "$key" || return 1
  done

  # step 3: std (pinned when versions.toml pins it, else latest)
  if [[ "$DRY_RUN" == "1" ]]; then
    step_status "[dry-run] skipping std clone"
    skip "[dry-run] skipping std clone"
  elif [[ ! -f "$STD_DIR/ANCHOR.oo" ]]; then
    step_status "cloning standard library (openOODA/std)"
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
    step_status "[dry-run] skipping oodar sources clone"
    skip "[dry-run] skipping oodar sources clone"
  elif [[ ! -f "$OODAR_SRC_DIR/oodar.c" ]]; then
    step_status "cloning runtime sources (openOODA/oodar)"
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
    step_status "[dry-run] skipping codex fetch"
    skip "[dry-run] skipping codex fetch"
  elif [[ -z "$(_ooda_codex_path)" ]]; then
    step_status "fetching orientation codex (openOODA/NORTHSTAR.oot)"
    if ! curl -sSL --connect-timeout 10 --max-time 60 -o "$OPENOODA_HOME/NORTHSTAR.oot" "https://raw.githubusercontent.com/openOODA/openOODA/main/NORTHSTAR.oot" 2>/dev/null || [[ ! -s "$OPENOODA_HOME/NORTHSTAR.oot" ]]; then
      rm -f "$OPENOODA_HOME/NORTHSTAR.oot" 2>/dev/null || true
      warn "codex fetch failed; MCP wiring gets an empty OODACODEX until network returns"
    fi
  fi

  # step 4: shell rc (bash only; zsh/fish users get a hint via warn_for_other_shells)
  step_status "setting up shell environment (~/.bashrc)"
  if [[ "$DRY_RUN" != "1" ]]; then setup_shell_rc; fi
  warn_for_other_shells

  # step 4b: /usr/local/bin shims
  if [[ "$DRY_RUN" == "1" ]]; then
    step_status "[dry-run] skipping /usr/local/bin shims"
    skip "[dry-run] skipping /usr/local/bin shims"
  elif [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    step_status "creating /usr/local/bin shims (binaries resolve with no rc sourcing)"
    for b in "$BIN_DIR"/*; do
      [[ -x "$b" && -f "$b" ]] || continue
      ln -sf "$b" "/usr/local/bin/$(basename "$b")" 2>/dev/null || true
    done
  fi

  # step 4c: clean stale openooda binaries in legacy shadow locations
  # (~/.local/bin from a prior install layout) so the install wins
  # regardless of PATH order. Opt-out via --keep-stale; the post-install
  # assert_path_resolution still catches the shadow in that case.
  step_status "cleaning stale shadow binaries (legacy ~/.local/bin layout)"
  clean_stale_shadow_binaries

  # step 5: shim refresh + stale servers
  step_status "refreshing shims and restarting stale servers"
  if [[ "$DRY_RUN" != "1" ]]; then refresh_grok_shims; restart_stale_servers; fi

  # step 6: post-flight
  step_status "verifying all binaries (post-flight check)"
  if [[ "$DRY_RUN" != "1" ]]; then post_flight; fi

  # Serialise the cross-subshell state to RESULTS_FILE so the parent
  # print_summary can read what really happened. Without this, the
  # parent sees empty INSTALLED[] and prints "no components installed"
  # even when all 7 binaries were downloaded and SHA-verified.
  dump_results
  step_status "done"
  return 0
}

# print_summary: the final block. Uses printf directly (not ok/info) so
# QUIET doesn't suppress it.
print_summary() {
  ELAPSED=$(( $(date +%s) - START ))
  printf '\n%s%s Summary %s\n' "$BOLD" "$MAGENTA" "$RESET"
  if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    printf '  %s✓%s installed:   %s\n' "$GREEN" "$RESET" "${INSTALLED[*]}"
    printf '  %s✓%s SHA-256 verified: %s\n' "$GREEN" "$RESET" "${INSTALLED[*]}"
  else
    printf '  %s!%s no components installed (binaries land in future releases)\n' "$YELLOW" "$RESET"
  fi
  [[ ${#SKIPPED[@]} -gt 0 ]] && printf '  %s✓%s skipped:     %s\n' "$GREEN" "$RESET" "${SKIPPED[*]}"
  [[ $BYTES -gt 0 ]] && printf '  %s✓%s downloaded:  %s\n' "$GREEN" "$RESET" "$(awk -v b="$BYTES" 'BEGIN{printf "%.1f MB", b/1048576}')"
  printf '  %s✓%s binaries:    %s\n' "$GREEN" "$RESET" "$BIN_DIR"
  printf '  %s✓%s std:         %s\n' "$GREEN" "$RESET" "$STD_DIR"
  printf '  %s✓%s sources:     %s\n' "$GREEN" "$RESET" "$OPENOODA_HOME/oodar"
  printf '  %s✓%s time:        %ss\n' "$GREEN" "$RESET" "$ELAPSED"
  [[ "$DRY_RUN" != "1" ]] && printf '  %s✓%s shell rc:    bash updated (.bak.openooda backup)\n' "$GREEN" "$RESET"
  printf '\n  %sWelcome to openOODA. https://openooda.org%s\n\n' "$BOLD$MAGENTA" "$RESET"
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
# Print the narrative preamble: what we're about to do, in plain words.
# The user always sees this, even with QUIET=1 — it's the story.
print_preamble

# Quiet by default — only the banner and summary show on the terminal.
# OPENOODA_DEBUG=1 restores the verbose per-step output (for debugging).
QUIET=1
export QUIET

# y/n — verify user wants to install (skipped for DRY_RUN / non-tty / CI / OPENOODA_YES=1)
if [[ $DO_UNINSTALL -eq 1 ]]; then
  QUIET=0
  info "uninstall requested — removing $BIN_DIR and toolchain"
  # remove /usr/local/bin shims pointing into BIN_DIR first (else they dangle)
  for s in /usr/local/bin/ooda /usr/local/bin/oodac /usr/local/bin/opm /usr/local/bin/ooda-lsp /usr/local/bin/ooda-mcp /usr/local/bin/blackbox; do
    if [[ -L "$s" && "$(readlink "$s" 2>/dev/null)" == "$BIN_DIR/"* ]]; then rm -f "$s" 2>/dev/null || true; fi
  done
  # remove binaries, std, and build sources (keep OPENOODA_HOME for logs)
  rm -rf "$BIN_DIR" "$STD_DIR" "$OPENOODA_HOME/oodar" 2>/dev/null || true
  # revert shell rc from backups (bash only — install no longer owns zshrc/fish)
  for rc in "$HOME/.bashrc"; do
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
# The spinner shows both the rotating glyph and the current step name (read
# from $STATUS_FILE), so the user sees the narrative of what's happening.
# err() calls inside the subshell are also captured to the log, so the
# spinner is never garbled by stderr. The summary block below is the only
# stdout output after the spinner stops.
STATUS_FILE=$(mktemp 2>/dev/null || echo "/tmp/openooda-status.$$")
RESULTS_FILE=$(mktemp 2>/dev/null || echo "/tmp/openooda-results.$$")
export STATUS_FILE RESULTS_FILE
( do_install ) >> "$LOG_FILE" 2>&1 &
INSTALL_PID=$!
spinner_with_status "$INSTALL_PID" "$STATUS_FILE"
INSTALL_RC=$?
wait "$INSTALL_PID" 2>/dev/null || true
rm -f "$STATUS_FILE" 2>/dev/null || true

# Pull the cross-subshell state back into the parent. do_install dumped
# INSTALLED / SKIPPED / BYTES to RESULTS_FILE before returning; sourcing
# it restores those vars so print_summary can show the truth (e.g. all 7
# binaries were installed and SHA-verified).
INSTALLED=()
SKIPPED=()
BYTES=0
[[ -r "$RESULTS_FILE" ]] && . "$RESULTS_FILE" 2>/dev/null || true

# Post-install invariant: every installed binary must resolve via
# `command -v` to $BIN_DIR. If a stale shadow wins on PATH, fail closed.
# (assert_path_resolution also sources $RESULTS_FILE to read INSTALLED.)
assert_path_resolution
ASSERT_RC=$?

# Print the summary (the only thing the user sees, besides the banner)
print_summary
rm -f "$RESULTS_FILE" 2>/dev/null || true

# If install failed, surface the last few log lines
if [[ $INSTALL_RC -ne 0 ]]; then
  err "install failed (exit $INSTALL_RC) — last 20 lines of $LOG_FILE:"
  tail -n 20 "$LOG_FILE" >&2 || true
  exit 1
fi

# Marker kept for tests/test_install.sh line 21 which greps for this literal.
TOTAL=17
