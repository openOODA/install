#!/bin/bash
# install 9.8 — fail-closed sha256 sidecar, blackbox, toolchain-only, bash rc, no shadow, no state-loss, opm-nonzero, on-disk accept
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
grep -q "clean_stale_shadow_binaries" install.sh || { echo "FAIL no clean_stale_shadow_binaries"; exit 1; }
grep -q "assert_path_resolution" install.sh || { echo "FAIL no assert_path_resolution"; exit 1; }
grep -q -- "--keep-stale" install.sh || { echo "FAIL no --keep-stale flag"; exit 1; }
grep -q "bak.openooda" install.sh || { echo "FAIL no backup"; exit 1; }
grep -q "DO_UNINSTALL" install.sh || { echo "FAIL no uninstall"; exit 1; }
grep -q "LOG_FILE" install.sh || { echo "FAIL no log"; exit 1; }
# New: cross-subshell state transfer must be fail-closed (Plan v26).
# dump_results writes atomically (tmp + mv) and propagates errors;
# the main flow has 3 guards (missing file, bad syntax, empty array).
grep -q "install state was lost" install.sh || { echo "FAIL no state-loss guard in source"; exit 1; }
grep -q "install state file is missing or unreadable" install.sh || { echo "FAIL no missing-file guard"; exit 1; }
grep -q "install state file has bad syntax" install.sh || { echo "FAIL no bad-syntax guard"; exit 1; }
grep -q 'mv -f "\$tmp" "\$RESULTS_FILE"' install.sh || { echo "FAIL no atomic rename in dump_results"; exit 1; }
# The misleading "binaries land in future releases" copy must be gone.
if grep -q "binaries land in future releases" install.sh; then
  echo "FAIL misleading 'binaries land in future releases' copy is back"; exit 1
fi
# Plan v27: post_flight must tolerate opm --help exiting 1. The pipeline
# capture in post_flight must end with `|| true` so the assignment does
# not propagate opm's non-zero exit and kill the subshell under
# set -e + pipefail before dump_results runs.
grep -E 'helpline=.*head -n 1 \|\| true' install.sh \
  || { echo "FAIL post_flight helpline capture does not swallow opm's non-zero exit"; exit 1; }
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
# Plan v28: assert_path_resolution must accept a binary present at $BIN_DIR
# even when command -v cannot resolve it on the current PATH (case (c)).
# This unblocks `ooda update` when the install subshell writes binaries
# but the parent shell's PATH does not yet include $BIN_DIR.
grep -q "case (c)" install.sh || { echo "FAIL no case (c) on-disk accept in assert_path_resolution"; exit 1; }
grep -q '\-x "\$dest" && \-z "\$resolved"' install.sh \
  || { echo "FAIL no on-disk accept clause (-x \$dest && -z \$resolved)"; exit 1; }
grep -q "command -v or on-disk" install.sh \
  || { echo "FAIL success-line not updated to mention on-disk accept"; exit 1; }
# Runtime check: load install.sh, exercise assert_path_resolution with
# PATH stripped to /usr/bin:/bin only, with a real binary at $BIN_DIR.
# Must succeed (case c) where it previously failed.
TMPD=$(mktemp -d); trap "rm -rf $TMPD" EXIT
RESULTS_FILE="$TMPD/r.sh"
cat > "$RESULTS_FILE" <<EOF
INSTALLED=("ooda" "oodac" "oodar" "opm" "lsp" "mcp" "blackbox")
EOF
# Extract just assert_path_resolution (plus the BINARIES declaration it
# references) into a script file, then run that script under a stripped
# PATH. Use awk for the extraction since multi-line sed is finicky.
awk '
  /^declare -A BINARIES=/ { print; next }
  /^assert_path_resolution\(\)/, /^}$/ { print; if (/^}$/) exit }
' install.sh > "$TMPD/assert.sh"
test -s "$TMPD/assert.sh" || { echo "FAIL could not extract assert_path_resolution from install.sh"; exit 1; }
env -i PATH=/usr/bin:/bin HOME="$HOME" BIN_DIR="$HOME/.openooda/bin" RESULTS_FILE="$RESULTS_FILE" \
  bash "$TMPD/assert.sh" \
  || { echo "FAIL on-disk accept case (c) did not trigger under stripped PATH"; exit 1; }
echo "PASS install 9.8 fail-closed sha256+blackbox+toolchain+bash-rc+no-shadow+no-state-loss+opm-nonzero+on-disk-accept"
