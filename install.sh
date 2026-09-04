#!/usr/bin/env bash
# openOODA one-line installer.
#   curl -fsSL https://openooda.org/install.sh | bash
# See versions.toml in this repo for per-component version pinning.
set -euo pipefail

OPENOODA_HOME="${OPENOODA_HOME:-$HOME/.openooda}"
BIN_DIR="$OPENOODA_HOME/bin"
STD_DIR="$OPENOODA_HOME/std"
RELEASES="https://github.com/openOODA"

declare -A REPOS=(
  [ooda]="ooda" [oodac]="oodac" [oodar]="oodar"
  [opm]="opm" [lsp]="lsp" [mcp]="mcp"
)
declare -A BINARIES=(
  [ooda]="ooda" [oodac]="oodac" [oodar]="liboodar.a"
  [opm]="opm" [lsp]="ooda-lsp" [mcp]="ooda-mcp"
)

# --- helpers -----------------------------------------------------------------

declare -A PINS=()
load_pins() {
  local f="$(dirname "${BASH_SOURCE[0]:-$0}")/versions.toml"
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

info() { printf '  \033[36m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

# --- detect host -------------------------------------------------------------

OS="$(uname -s)"; case "$OS" in Linux) OS=linux ;; Darwin) OS=darwin ;;
  *) err "unsupported OS: $OS (need linux or darwin)"; exit 1 ;; esac
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) err "unsupported arch: $ARCH (need x86_64 or arm64)"; exit 1 ;; esac

# --- install -----------------------------------------------------------------

INSTALLED=(); SKIPPED=()
install_component() {
  local key="$1" url dest
  url="$(release_url "$key")"
  dest="$BIN_DIR/${BINARIES[$key]}"
  local code; code="$(curl -sSL -o /dev/null -w '%{http_code}' -I "$url" || true)"
  if [[ "$code" != "200" && "$code" != "302" ]]; then
    info "${key}: — not yet shipped (${BINARIES[$key]}-${OS}-${ARCH})"
    SKIPPED+=("$key"); return 0
  fi
  if curl -fsSL -o "$dest" "$url"; then
    chmod +x "$dest"; ok "${key}: installed $(basename "$dest")"
    INSTALLED+=("$key")
  else
    warn "${key}: download failed ($url)"; SKIPPED+=("$key")
  fi
}

clone_std() {
  if [[ -d "$STD_DIR" ]]; then ok "std: already present at $STD_DIR"; return 0; fi
  if ! command -v git >/dev/null 2>&1; then
    warn "std: git not found; skipping. install git then run:"
    warn "     git clone --depth 1 https://github.com/openOODA/std $STD_DIR"
    return 0
  fi
  info "std: cloning https://github.com/openOODA/std ..."
  if git clone --depth 1 https://github.com/openOODA/std "$STD_DIR" >/dev/null 2>&1; then
    ok "std: cloned to $STD_DIR"
  else
    warn "std: clone failed; retry manually:"
    warn "     git clone --depth 1 https://github.com/openOODA/std $STD_DIR"
  fi
}

setup_shell_rc() {
  local l1='export PATH="$HOME/.openooda/bin:$PATH"'
  local l2='export OODA_STD_ROOT="$HOME/.openooda/std"'
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    # ensure the rc file exists; if it does not, try to create it
    if [[ ! -e "$rc" ]]; then
      if ! { : >> "$rc"; } 2>/dev/null; then
        continue   # cannot create (e.g. $HOME not writable) — skip silently
      fi
    elif ! { : >> "$rc"; } 2>/dev/null; then
      warn "shell rc: $(basename "$rc") not writable; add these lines manually:"
      warn "           $l1"; warn "           $l2"
      continue
    fi
    if grep -Fqx "$l1" "$rc" 2>/dev/null; then
      info "shell rc: $(basename "$rc") already has openOODA exports"
    else
      printf '\n# openOODA\n%s\n%s\n' "$l1" "$l2" >> "$rc"
      ok "shell rc: $(basename "$rc") updated"
    fi
  done
}

# --- main --------------------------------------------------------------------

printf '\n\033[1mopenOODA installer\033[0m\n\n'
load_pins
info "host: ${OS}/${ARCH}"
mkdir -p "$BIN_DIR"; ok "install dir: $BIN_DIR"

printf '\n\033[1mComponents\033[0m\n'
for key in "${!REPOS[@]}"; do install_component "$key"; done

printf '\n\033[1mStandard library\033[0m\n'
clone_std

printf '\n\033[1mShell environment\033[0m\n'
setup_shell_rc

printf '\n\033[1mSummary\033[0m\n'
if [[ ${#INSTALLED[@]} -gt 0 ]]; then ok "installed: ${INSTALLED[*]}"
else warn "no components installed (binaries not yet published)"; fi
[[ ${#SKIPPED[@]} -gt 0 ]] && info "skipped:   ${SKIPPED[*]}"
ok "binaries:       $BIN_DIR"
ok "std:            $STD_DIR"
ok "shell env:      PATH + OODA_STD_ROOT set in ~/.bashrc and ~/.zshrc"
printf '\nRestart your shell (or: source ~/.bashrc) and try:\n  ooda --help\n\n'
