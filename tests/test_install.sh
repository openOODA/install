#!/bin/bash
# install 9.4 — fail-closed sha256 sidecar, blackbox, toolchain-only, bash rc
set -e
grep -q "sha256" install.sh || { echo "FAIL no sha256"; exit 1; }
grep -q "missing SHA-256 sidecar" install.sh || { echo "FAIL no missing-sidecar refuse"; exit 1; }
grep -q "refuse unsigned install" install.sh || { echo "FAIL no refuse unsigned"; exit 1; }
if grep -q '\[\[ -n "$expected_hash" &&' install.sh; then
  echo "FAIL empty expected_hash still skip-opens"; exit 1
fi
bash install.sh --selftest-sha
grep -q "blackbox" install.sh || { echo "FAIL no blackbox"; exit 1; }
grep -q "BINARIES.*blackbox" install.sh || { echo "FAIL no blackbox binary"; exit 1; }
grep -q "OODA_COMPILER" install.sh || { echo "FAIL no OODA_COMPILER env"; exit 1; }
grep -q "OODA_FS_READDIR" install.sh || { echo "FAIL no OODA_FS_READDIR"; exit 1; }
grep -q "TOTAL=17" install.sh || { echo "FAIL TOTAL not 17 (sysdep/sources/shim/codex steps missing)"; exit 1; }
grep -q "ensure_sysdep" install.sh || { echo "FAIL no sysdep ensure"; exit 1; }
grep -q "OODAR_SRC_DIR" install.sh || { echo "FAIL no oodar sources step"; exit 1; }
grep -q "/usr/local/bin" install.sh || { echo "FAIL no local-bin shims"; exit 1; }
grep -q "ask_confirm" install.sh || { echo "FAIL no y/n prompt"; exit 1; }
grep -q "Welcome to version" install.sh || { echo "FAIL no version welcome"; exit 1; }
grep -q "Would you like to install openOODA" install.sh || { echo "FAIL no install y/n new"; exit 1; }
grep -q "pre_flight" install.sh || { echo "FAIL no pre-flight"; exit 1; }
grep -q "post_flight" install.sh || { echo "FAIL no post-flight"; exit 1; }
grep -q "XDG_CONFIG_HOME" install.sh || { echo "FAIL no XDG"; exit 1; }
grep -q 'for rc in "\$HOME/.bashrc";' install.sh || { echo "FAIL shell rc loop not bash-only"; exit 1; }
grep -q "warn_for_other_shells" install.sh || { echo "FAIL no warn_for_other_shells"; exit 1; }
grep -q "bak.openooda" install.sh || { echo "FAIL no backup"; exit 1; }
grep -q "DO_UNINSTALL" install.sh || { echo "FAIL no uninstall"; exit 1; }
grep -q "LOG_FILE" install.sh || { echo "FAIL no log"; exit 1; }
python3 - <<'PY' || { echo "FAIL server env missing OODA_FS_WRITEDIR"; exit 1; }
import re
src = open("install.sh").read()
toml = {}
cur = None
for i, ln in enumerate(src.split("\n")):
    s = ln.strip()
    if re.match(r"\[mcp_servers\.\w+\.env\]", s):
        cur = i
    elif cur is not None and (not s or s.startswith("[") or s == "TOML"):
        toml[cur] = (cur, i)
        cur = None
for i, ln in enumerate(src.split("\n")):
    if "OODA_FS_READDIR" not in ln:
        continue
    window = ln + (src.split("\n")[i + 1] if i + 1 < len(src.split("\n")) else "")
    if "OODA_FS_WRITEDIR" in window or "export OODA_FS_READDIR" in ln:
        continue
    in_toml = [b for b in toml.values() if b[0] <= i <= b[1]]
    if in_toml and any("OODA_FS_WRITEDIR" in src.split("\n")[k] for k in range(in_toml[0][0], in_toml[0][1] + 1)):
        continue
    raise SystemExit(f"FAIL no WRITEDIR near READDIR line {i + 1}: {ln[:80]}")
PY
if grep -q 'BIN_DIR/ooda-mcp-grok\|BIN_DIR/ooda-lsp-grok\|bindir+"/ooda-lsp-grok"' install.sh; then
  echo "FAIL stale -grok shim command refs (never shipped)"; exit 1
fi
grep -q "NORTHSTAR.oot" install.sh || { echo "FAIL no codex fetch"; exit 1; }
echo "PASS install 9.4 fail-closed sha256+blackbox+toolchain+bash-rc"
