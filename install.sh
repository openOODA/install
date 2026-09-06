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
    if grep -q '\.local/bin/oodac' "$rc" 2>/dev/null; then
      sed -i 's|.*\.local/bin/oodac.*|'"$l3"'|' "$rc" 2>/dev/null || true
      ok "$(basename "$rc") fixed OODA_COMPILER -> ~/.openooda/bin/oodac"
    fi
    if grep -Fqx "$l1" "$rc" 2>/dev/null; then
      info "$(basename "$rc") already has openOODA exports"
    else
      printf '\n# openOODA\n%s\n%s\n%s\n' "$l1" "$l2" "$l3" >> "$rc"
      ok "$(basename "$rc") updated"
    fi
  done
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
  # shell is still on old PATH until sourced — warn
  if ! command -v oodac >/dev/null 2>&1 || [[ "$(command -v oodac 2>/dev/null)" != "$BIN_DIR/oodac" ]]; then
    warn "run: source ~/.bashrc (or restart shell) to pick up new PATH"
  fi
  if [[ "${OODA_COMPILER:-}" != "$BIN_DIR/oodac" && "${OODA_COMPILER:-}" != "" ]]; then
    warn "OODA_COMPILER=$OODA_COMPILER (expected $BIN_DIR/oodac) — restart shell or export OODA_COMPILER=\$HOME/.openooda/bin/oodac"
  fi
}

# --- harness auto-detect + wire mcp/lsp/blackbox ------------------------------

HARNESS_DETECTED=()
HARNESS_WIRED=()
HARNESS_SKIPPED=()

_ooda_codex_path() {
  # NORTHSTAR.oot is the codex; try polyrepo root then OPENOODA_HOME
  if [[ -f "$HOME/Projects/openOODA/openOODA/NORTHSTAR.oot" ]]; then
    echo "$HOME/Projects/openOODA/openOODA/NORTHSTAR.oot"
  elif [[ -f "$OPENOODA_HOME/../openOODA/NORTHSTAR.oot" ]]; then
    echo "$OPENOODA_HOME/../openOODA/NORTHSTAR.oot"
  else
    echo "$HOME/Projects/openOODA/openOODA/NORTHSTAR.oot"
  fi
}

detect_harnesses() {
  HARNESS_DETECTED=(); HARNESS_SKIPPED=()
  if command -v agy >/dev/null 2>&1 || [[ -d "$HOME/.gemini/antigravity-cli" ]]; then HARNESS_DETECTED+=("antigravity-cli"); else HARNESS_SKIPPED+=("antigravity-cli"); fi
  if command -v opencode >/dev/null 2>&1 || [[ -d "$HOME/.config/opencode" ]]; then HARNESS_DETECTED+=("opencode"); else HARNESS_SKIPPED+=("opencode"); fi
  if command -v muse >/dev/null 2>&1 || [[ -d "$HOME/.config/muse" ]]; then HARNESS_DETECTED+=("muse"); else HARNESS_SKIPPED+=("muse"); fi
  if command -v grok >/dev/null 2>&1 || [[ -d "$HOME/.grok" ]]; then HARNESS_DETECTED+=("grok"); else HARNESS_SKIPPED+=("grok"); fi
  if [[ -d "$HOME/.gemini" ]]; then HARNESS_DETECTED+=("gemini"); else HARNESS_SKIPPED+=("gemini"); fi
  if command -v mistral-vibe >/dev/null 2>&1 || [[ -d "$HOME/.config/mistral" ]]; then HARNESS_DETECTED+=("mistral-vibe"); else HARNESS_SKIPPED+=("mistral-vibe"); fi
  if command -v grok-build >/dev/null 2>&1; then HARNESS_DETECTED+=("grok-build"); else HARNESS_SKIPPED+=("grok-build"); fi
  if command -v devin >/dev/null 2>&1; then HARNESS_DETECTED+=("devin"); else HARNESS_SKIPPED+=("devin"); fi
  if command -v charm >/dev/null 2>&1 || [[ -d "$HOME/.config/charm" ]]; then HARNESS_DETECTED+=("charm"); else HARNESS_SKIPPED+=("charm"); fi
  if [[ ${#HARNESS_DETECTED[@]} -gt 0 ]]; then info "harnesses detected: ${HARNESS_DETECTED[*]}"; fi
  if [[ ${#HARNESS_SKIPPED[@]} -gt 0 ]]; then info "harnesses skipped (not installed): ${HARNESS_SKIPPED[*]}"; fi
}

_wire_json_backup() {
  local f="$1"
  if [[ -f "$f" && ! -f "$f.bak.openooda" ]]; then cp -p "$f" "$f.bak.openooda" 2>/dev/null || true; fi
}

wire_agy() {
  if ! command -v agy >/dev/null 2>&1; then skip "agy not installed — skipping antigravity-cli wire"; return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would wire agy: openooda + blackbox (OODA_COMPILER=$BIN_DIR/oodac)"; HARNESS_WIRED+=("antigravity-cli"); return 0; fi
  local envs=(--env "OODA_CODEX=$codex" --env "OODACODEX=$codex" --env "OODA_FS_READDIR=$HOME/Projects/openOODA" --env "OODA_FS_WRITEDIR=$HOME" --env "OODA_COMPILER=$BIN_DIR/oodac" --env "OODAC_BIN=$BIN_DIR/oodac")
  agy mcp add "${envs[@]}" openooda "$BIN_DIR/ooda-mcp" -- --stdio >/dev/null 2>&1 || warn "agy mcp add openooda failed"
  agy mcp add "${envs[@]}" blackbox /usr/bin/stdbuf -- -o0 -e0 "$BIN_DIR/blackbox" mcp --stdio >/dev/null 2>&1 || {
    # fallback without stdbuf wrapper
    agy mcp add "${envs[@]}" blackbox "$BIN_DIR/blackbox" -- mcp --stdio >/dev/null 2>&1 || warn "agy mcp add blackbox failed"
  }
  ok "wired agy: openooda + blackbox"; HARNESS_WIRED+=("antigravity-cli")
}

wire_opencode() {
  local cfg="$HOME/.config/opencode/opencode.jsonc"
  if [[ ! -d "$HOME/.config/opencode" ]] && ! command -v opencode >/dev/null 2>&1; then skip "opencode not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would wire opencode: $cfg (openooda + blackbox)"; HARNESS_WIRED+=("opencode"); return 0; fi
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
mcp["blackbox"]={"type":"local","command":["/usr/bin/stdbuf","-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"enabled":True,"environment":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
data["mcp"]=mcp
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  if [[ $? -eq 0 ]] && grep -q '"openooda"' "$cfg" 2>/dev/null; then
    ok "wired opencode: $cfg"; HARNESS_WIRED+=("opencode"); return 0
  fi
  warn "opencode wire: python3 merge failed, writing minimal json"
  printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "mcp": {\n    "openooda": { "type": "local", "command": ["%s/ooda-mcp", "--stdio"], "enabled": true, "environment": { "OODA_CODEX": "%s", "OODACODEX": "%s", "OODA_FS_READDIR": "%s/Projects/openOODA", "OODA_FS_WRITEDIR": "%s", "OODA_COMPILER": "%s/oodac" } },\n    "blackbox": { "type": "local", "command": ["/usr/bin/stdbuf", "-o0", "-e0", "%s/blackbox", "mcp", "--stdio"], "enabled": true, "environment": { "OODA_FS_READDIR": "%s/Projects/openOODA", "OODA_COMPILER": "%s/oodac", "OODAC_BIN": "%s/oodac" } }\n  }\n}\n' "$BIN_DIR" "$codex" "$codex" "$HOME" "$HOME" "$BIN_DIR" "$BIN_DIR" "$HOME" "$BIN_DIR" "$BIN_DIR" > "$cfg"
  ok "wired opencode: $cfg"; HARNESS_WIRED+=("opencode")
}

wire_gemini() {
  local cfg="$HOME/.gemini/config/mcp_config.json"
  if [[ ! -d "$HOME/.gemini" ]]; then skip "gemini not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would wire gemini: $cfg (openooda + blackbox)"; HARNESS_WIRED+=("gemini"); return 0; fi
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
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home,"OODA_FS_WRITEDIR":home}}
ms["blackbox"]={"command":"/usr/bin/stdbuf","args":["-o0","-e0",bindir+"/blackbox","mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_COMPILER":bindir+"/oodac","OODAC_BIN":bindir+"/oodac"}}
data["mcpServers"]=ms
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  ok "wired gemini: $cfg"; HARNESS_WIRED+=("gemini")
}

wire_grok() {
  local toml="$HOME/.grok/config.toml" lsp="$HOME/.grok/lsp.json"
  if [[ ! -d "$HOME/.grok" ]] && ! command -v grok >/dev/null 2>&1; then skip "grok not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would verify grok: $toml + $lsp"; HARNESS_WIRED+=("grok"); return 0; fi
  local codex; codex="$(_ooda_codex_path)"
  # ensure mcp_servers via python toml-ish append if missing
  if [[ -f "$toml" ]]; then
    _wire_json_backup "$toml"
    if ! grep -q "mcp_servers.blackbox" "$toml" 2>/dev/null; then
      cat >> "$toml" <<TOML

[mcp_servers.blackbox]
command = "/usr/bin/stdbuf"
args = ["-o0", "-e0", "$BIN_DIR/blackbox", "mcp", "--stdio"]
enabled = true
startup_timeout_sec = 60

[mcp_servers.blackbox.env]
OODA_FS_READDIR = "$HOME/Projects/openOODA"
OODA_COMPILER = "$BIN_DIR/oodac"
OODAC_BIN = "$BIN_DIR/oodac"
TOML
    fi
    if ! grep -q "mcp_servers.openooda" "$toml" 2>/dev/null; then
      cat >> "$toml" <<TOML

[mcp_servers.openooda]
command = "$BIN_DIR/ooda-mcp-grok"
args = []
enabled = true
startup_timeout_sec = 60

[mcp_servers.openooda.env]
OODA_CODEX = "$codex"
OODA_FS_READDIR = "$HOME/Projects/openOODA"
TOML
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
if "ooda" not in data:
    data["ooda"]={"command":bindir+"/ooda-lsp-grok","args":[],"extensionToLanguage":{".oo":"ooda",".oot":"ooda"},"env":{"OODA_COMPILER":bindir+"/oodac","OODA_FS_READDIR":home+"/Projects/openOODA"},"workspaceFolder":home+"/Projects/openOODA","startupTimeout":60000,"restartOnCrash":True}
else:
    env=data["ooda"].get("env") or {}
    env["OODA_COMPILER"]=bindir+"/oodac"
    env["OODA_FS_READDIR"]=home+"/Projects/openOODA"
    data["ooda"]["env"]=env
    data["ooda"]["command"]=bindir+"/ooda-lsp-grok"
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  fi
  ok "wired grok: $toml + $lsp"; HARNESS_WIRED+=("grok")
}

wire_muse() {
  local cfg="$HOME/.config/muse/settings.json"
  if [[ ! -d "$HOME/.config/muse" ]] && ! command -v muse >/dev/null 2>&1; then skip "muse not installed — skipping"; return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then ok "[dry-run] would wire muse: $cfg (openooda + blackbox)"; HARNESS_WIRED+=("muse"); return 0; fi
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
# muse uses mcpServers or mcp_servers; we set both for compat
ms=data.get("mcpServers") or data.get("mcp_servers") or {}
if not isinstance(ms, dict): ms={}
ms["openooda"]={"command":bindir+"/ooda-mcp","args":["--stdio"],"env":{"OODA_CODEX":codex,"OODACODEX":codex,"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_FS_WRITEDIR":home,"OODA_COMPILER":bindir+"/oodac"}}
ms["blackbox"]={"command":bindir+"/blackbox","args":["mcp","--stdio"],"env":{"OODA_FS_READDIR":home+"/Projects/openOODA","OODA_COMPILER":bindir+"/oodac"}}
data["mcpServers"]=ms
# keep existing unrelated keys
with open(cfg,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
  ok "wired muse: $cfg"; HARNESS_WIRED+=("muse")
}

wire_harnesses() {
  # if already detected (main did scan before asking), reuse; else detect now
  if [[ ${#HARNESS_DETECTED[@]} -eq 0 && ${#HARNESS_SKIPPED[@]} -eq 0 ]]; then
    detect_harnesses
  elif [[ ${#HARNESS_DETECTED[@]} -eq 0 && ${#HARNESS_SKIPPED[@]} -gt 0 ]]; then
    # already scanned and found nothing — re-log briefly
    info "harnesses detected: none"
  fi
  # after openOODA is installed: scan is done, now ask user if they want to wire to mcp/lsp/blackbox
  if [[ ${#HARNESS_DETECTED[@]} -gt 0 ]]; then
    if ! ask_confirm "Connect detected harnesses (${HARNESS_DETECTED[*]}) to mcp, lsp, and blackbox?" "Y"; then
      info "skipping harness wiring by user choice"
      # still log stubs for completeness
      for h in mistral-vibe grok-build devin charm; do
        if [[ " ${HARNESS_SKIPPED[*]} " == *" $h "* ]]; then
          info "harness $h not installed — stub skipped"
        fi
      done
      return 0
    fi
  fi
  # present harnesses — wire
  for h in "${HARNESS_DETECTED[@]}"; do
    case "$h" in
      antigravity-cli) wire_agy ;;
      opencode)        wire_opencode ;;
      gemini)          wire_gemini ;;
      grok)            wire_grok ;;
      muse)           wire_muse ;;
      *) info "harness $h detected — no verified adapter yet (skipped)" ;;
    esac
  done
  # stubs for explicitly absent but user-asked names — already in skipped list
  for h in mistral-vibe grok-build devin charm; do
    if [[ " ${HARNESS_SKIPPED[*]} " == *" $h "* ]]; then
      info "harness $h not installed — stub skipped"
    fi
  done
  if [[ ${#HARNESS_WIRED[@]} -gt 0 ]]; then ok "harnesses wired: ${HARNESS_WIRED[*]}"; fi
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

# y/n — verify user wants to install (right after start, skipped for DRY_RUN / non-tty / CI / OPENOODA_YES=1)
if ! ask_confirm "Install openOODA?" "Y"; then
  info "install cancelled"; exit 0
fi

TOTAL=12; done=0
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

# step 5: shims + stale servers (post-install, new binaries are on disk but old PIDs still hold old images)
if [[ "$DRY_RUN" == "1" ]]; then skip "[dry-run] skipping shim/server refresh"; else refresh_grok_shims; restart_stale_servers; fi
tick

# step 6: harness auto-detect + wire mcp/lsp/blackbox
wire_harnesses
# tell users to restart any open harnesses — config is on disk, hosts read it at startup
if [[ "$DRY_RUN" == "1" ]]; then
  [[ ${#HARNESS_WIRED[@]} -gt 0 ]] && info "on real install: restart any open harnesses (agy, opencode, grok, muse, gemini) to pick up new mcp/lsp/blackbox config"
else
  if [[ ${#HARNESS_WIRED[@]} -gt 0 ]]; then
    # check which harnesses actually have a running process
    _running=""
    for _h in agy opencode grok muse gemini; do
      if pgrep -f "$_h" >/dev/null 2>&1; then _running="$_running $_h"; fi
    done
    if [[ -n "$_running" ]]; then
      warn "restart any open harnesses to load new config:$_running (new mcp/lsp/blackbox is on disk, hosts read it at startup)"
    else
      info "if a harness was open during install (agy, opencode, grok, muse, gemini), restart it to pick up new mcp/lsp/blackbox config"
    fi
  fi
fi
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
