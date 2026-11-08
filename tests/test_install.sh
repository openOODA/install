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
if grep -q '\[bb\]=bb' install.sh; then echo "FAIL bb mapping present (bb retired)"; exit 1; fi
grep -q "OODA_COMPILER" install.sh || { echo "FAIL no OODA_COMPILER env"; exit 1; }
grep -q "OODA_FS_READDIR" install.sh || { echo "FAIL no OODA_FS_READDIR"; exit 1; }
grep -q "TOTAL=17" install.sh || { echo "FAIL TOTAL not 17 (sysdep/sources/shim/codex steps missing)"; exit 1; }
grep -q "ensure_sysdep" install.sh || { echo "FAIL no sysdep ensure"; exit 1; }
grep -q 'liboodar.a' install.sh || { echo "FAIL no oodar artifact (liboodar.a)"; exit 1; }
if grep -q 'ln -sf' install.sh; then echo "FAIL installer still uses ln -sf"; exit 1; fi
grep -q 'PATH via shell rc' install.sh || { echo "FAIL no PATH-via-rc (no /usr/local/bin shims)"; exit 1; }
grep -q "ask_confirm" install.sh || { echo "FAIL no y/n prompt"; exit 1; }
grep -q "Welcome to version" install.sh || { echo "FAIL no version welcome"; exit 1; }
grep -q "Later: ooda update" install.sh || { echo "FAIL no ooda update hint"; exit 1; }
grep -q "Would you like to install openOODA" install.sh || { echo "FAIL no install y/n new"; exit 1; }
grep -q "pre_flight" install.sh || { echo "FAIL no pre-flight"; exit 1; }
grep -q "post_flight" install.sh || { echo "FAIL no post-flight"; exit 1; }
grep -q "XDG_CONFIG_HOME" install.sh || { echo "FAIL no XDG"; exit 1; }
grep -q '\.bashrc' install.sh && grep -q '\.bash_profile' install.sh && grep -q '\.zshrc' install.sh || { echo "FAIL shell rc loop missing multi-shell support"; exit 1; }
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
# Parent must wait the install PID for the real RC; spinner printf is always 0.
# set -e must be off around that wait, or a failed child never reaches the log tail.
grep -q 'wait "\$INSTALL_PID"' install.sh || { echo "FAIL no wait INSTALL_PID"; exit 1; }
if grep -n 'wait "\$INSTALL_PID"' install.sh | grep -q '|| true'; then
  echo "FAIL wait INSTALL_PID still discards the child RC"
  exit 1
fi
grep -q "trap 'dump_results || true' EXIT" install.sh || { echo "FAIL no dump_results EXIT trap"; exit 1; }
awk '
  /wait "\$INSTALL_PID"/ {
    for (j=NR-5; j<=NR; j++) if (lines[j] ~ /set \+e/) found=1
  }
  { lines[NR]=$0 }
  END { if (!found) { print "FAIL wait INSTALL_PID not under set +e"; exit 1 } }
' install.sh || exit 1
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
grep -q "AGENTS.md" install.sh || { echo "FAIL no codex fetch"; exit 1; }
grep -q "cards/spec.md" install.sh || { echo "FAIL no spec fetch"; exit 1; }
grep -q "OODASPEC" install.sh || { echo "FAIL no OODASPEC env"; exit 1; }
grep -q "OODA_SPEC" install.sh || { echo "FAIL no OODA_SPEC env"; exit 1; }
grep -q 'spec[[:space:]]\+~/.openooda/cards/spec.md' install.sh \
  || { echo "FAIL no spec preamble"; exit 1; }
grep -q 'rm -rf.*cards/spec.md' install.sh \
  || { echo "FAIL no cards/spec.md uninstall removal"; exit 1; }
grep -q 'sed -i.*OODASPEC' install.sh \
  || { echo "FAIL no OODASPEC uninstall cleanup"; exit 1; }
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
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
RESULTS_FILE="$TMPD/r.sh"
cat > "$RESULTS_FILE" <<EOF
INSTALLED=("ooda")
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
# Plan v29: --from-source builds from a local checkout instead of downloading.
# Structural: flag + env + build map + bootstrap fail-closed + oodac keep-note
# (unique_fns) + honest summary line (never "SHA-256 verified" for built bins).
grep -q -- "--from-source" install.sh || { echo "FAIL no --from-source flag"; exit 1; }
grep -q "OPENOODA_SOURCE" install.sh || { echo "FAIL no OPENOODA_SOURCE env"; exit 1; }
grep -q "SOURCE_MAIN" install.sh || { echo "FAIL no SOURCE_MAIN build map"; exit 1; }
grep -q "needs an installed oodac as bootstrap" install.sh || { echo "FAIL no bootstrap fail-closed"; exit 1; }
grep -q "unique_fns" install.sh || { echo "FAIL no unique_fns oodac keep-note"; exit 1; }
grep -q "built from source" install.sh || { echo "FAIL no built-from-source summary line"; exit 1; }
grep -q "network skipped (from-source)" install.sh || { echo "FAIL no from-source network degrade"; exit 1; }
grep -q 'chmod +x "$BIN_DIR/liboodar.a"' install.sh || { echo "FAIL from-source oodar not marked executable (breaks assert_path_resolution)"; exit 1; }
# Runtime: bogus source dir must fail closed even in dry-run (no network needed).
if OPENOODA_HOME="$TMPD/home" bash install.sh --from-source=/nonexistent-openooda-src --dry-run >/dev/null 2>&1; then
  echo "FAIL --from-source bogus dir did not fail closed"; exit 1
fi
# Runtime: --help must advertise the flag.
bash install.sh --help 2>&1 | grep -q -- "--from-source" || { echo "FAIL --help hides --from-source"; exit 1; }
# Runtime: valid-dir dry-run must NOT demand a bootstrap oodac (regression:
# dry-run failed closed requiring a compiler it never invokes). Fixture
# checkout is empty marker files (resolve only checks existence); stripped
# PATH proves no oodac is consulted.
mkdir -p "$TMPD/fakesrc/oostd" "$TMPD/fakesrc/oopm/cli" "$TMPD/fakesrc/oolsp/cli" "$TMPD/fakesrc/oomcp/cli" "$TMPD/fakesrc/oodar/scripts" "$TMPD/fakesrc/openOODA/cards" "$TMPD/fakesrc/ooda"
for f in ooda/main.oo oopm/cli/main.oo oolsp/cli/main.oo oomcp/cli/main.oo oodar/scripts/Makefile openOODA/AGENTS.md openOODA/cards/spec.md oostd/anchor.oo; do : > "$TMPD/fakesrc/$f"; done
if ! env -i PATH=/usr/bin:/bin HOME="$HOME" OPENOODA_HOME="$TMPD/home2" bash install.sh --from-source="$TMPD/fakesrc" --dry-run >/dev/null 2>&1; then
  echo "FAIL --from-source dry-run demanded a bootstrap oodac"; exit 1
fi
# The ooda-tui double-install is retired: one binary named tui. The
# preamble must list it plainly, no path may copy it to a second name,
# and the stale alias left by older installers must be removed.
if grep -q '(also ooda-tui)' install.sh; then echo "FAIL preamble still apologizes for ooda-tui"; exit 1; fi
if grep -q 'cp -f "$dest" "$BIN_DIR/ooda-tui"' install.sh; then echo "FAIL double-install copy remains"; exit 1; fi
grep -qE 'for stale in .*ooda-tui' install.sh || { echo "FAIL no stale-alias removal"; exit 1; }
# Canonical package resolution: component repos are the openOODA-core
# names (ooda oodac oodar opm oolsp oomcp). Legacy ooda-* package
# names must never appear as repo keys or install destinations.
if grep -qE 'ooda-(cockpit|compositor|files|lock|panel|portal)' install.sh; then
  echo "FAIL legacy ooda-* package name present"; exit 1
fi
repos_keys=$(grep -oE '^declare -A REPOS=\(\[[a-z]+\]=[a-z.-]+( \[[a-z]+\]=[a-z.-]+)*\)' install.sh | grep -oE '\[[a-z]+\]' | tr -d '[]' | sort | tr '\n' ' ')
expected="ooda oodac oodar oolsp oomcp oopm "
[ "$repos_keys" = "$expected" ] || { echo "FAIL REPOS keys not canonical: $repos_keys"; exit 1; }
bin_vals=$(grep -oE '^declare -A BINARIES=\(\[[a-z]+\]=[a-z.-]+( \[[a-z]+\]=[a-z.-]+)*\)' install.sh | grep -oE '=[a-z.-]+' | tr -d '=' | sort -u | tr '\n' ' ')
for bv in $bin_vals; do
  case "$bv" in ooda|oodac|liboodar.a|oopm|opm|oolsp|ooda-lsp|oomcp|ooda-mcp) ;; *) echo "FAIL non-canonical dest name: $bv"; exit 1;; esac
done
# Plan v30: versions.toml pin parsing is a trust boundary. Extract the
# real declare+load_pins pair and feed it a hostile manifest: malformed
# version strings and path-traversal keys must never reach PINS.
awk '
  /^declare -A PINS=/ { print; next }
  /^load_pins\(\)/, /^\}/ { print; if (/^\}/) exit }
' install.sh > "$TMPD/pins.sh"
test -s "$TMPD/pins.sh" || { echo "FAIL could not extract load_pins from install.sh"; exit 1; }
cat > "$TMPD/versions.toml" <<'EOF'
# valid pins — the only entries that may load
oodar = "v1.2.3"
std = "v0.4.0"
STD = "v9.9.9"

# malformed version strings — all refused by the pin regex
cli = "1.2.3"
tui = "v1.2"
opm = "v1.2.3.4"
lsp = "v1.2.3-beta"
mcp = "v1.2.3; rm -rf /"
oodac = "v1.2"

# path-traversal and non-token keys — all refused
../evil = "v9.9.9"
a/b = "v9.9.9"
std.extra = "v9.9.9"
"quoted" = "v1.2.3"
key-with-dash = "v1.2.3"
key_with_under = "v1.2.3"

# unquoted, single-quoted, and empty values — all refused
bad1 = v1.2.3
bad2 = 'v1.2.3'
bad3 = ""

# adversarial version forms — refused by the strict "vX.Y.Z" grammar
bad4 = "V1.2.3"
bad5 = "v1.2.3 "
bad6 = "v1.2.3+build"
bad7 = "vv1.2.3"
bad8 = "v1.2.3\n"
bad9 = "v1.2.3#"
9lives = "v1.2.3"
# non-ASCII keys (e.g. "ké") are locale-dependent: UTF-8 collation may
# fold them into [a-zA-Z] while C locale refuses. They are inert either
# way — PINS is only read by literal ASCII component names — so no
# assertion pins the behavior.
EOF
bash -c '
  source "$1"
  load_pins
  fail=0
  [ "${#PINS[@]}" -eq 3 ] || { echo "FAIL pin count ${#PINS[@]} (want 3: oodar,std,STD)"; declare -p PINS; fail=1; }
  [ "${PINS[oodar]:-}" = "v1.2.3" ] || { echo "FAIL oodar pin"; fail=1; }
  [ "${PINS[std]:-}" = "v0.4.0" ] || { echo "FAIL std pin"; fail=1; }
  [ "${PINS[STD]:-}" = "v9.9.9" ] || { echo "FAIL STD uppercase-key pin (documents case-sensitive lookup)"; fail=1; }
  for k in cli tui opm lsp mcp oodac bad1 bad2 bad3 bad4 bad5 bad6 bad7 bad8 bad9 9lives; do
    [ -z "${PINS[$k]:-}" ] || { echo "FAIL malformed pin accepted: $k=${PINS[$k]}"; fail=1; }
  done
  for k in "../evil" "a/b" "std.extra" "quoted" "key-with-dash" "key_with_under"; do
    [ -z "${PINS[$k]:-}" ] || { echo "FAIL traversal/weird key accepted: $k"; fail=1; }
  done
  exit $fail
' _ "$TMPD/pins.sh" || { echo "FAIL load_pins accepted hostile versions.toml entries"; exit 1; }
# Lenient edges documented: the pin grammar is quote-anchored but not
# end-anchored — duplicate keys resolve last-wins, trailing bytes after
# the closing quote are ignored, and leading-zero components pass [0-9]+
# (a malformed pin then 404s fail-closed at fetch time, never installs).
cat > "$TMPD/versions.toml" <<'EOF'
dup = "v1.0.0"
dup = "v2.0.0"
trail = "v9.9.9"junk
pad = "v03.4.5"
compact="v5.0.0"
cmt = "v6.0.0" # pinned by fleet
EOF
bash -c '
  source "$1"
  load_pins
  fail=0
  [ "${PINS[dup]:-}" = "v2.0.0" ] || { echo "FAIL dup pin not last-wins: ${PINS[dup]}"; fail=1; }
  [ "${PINS[trail]:-}" = "v9.9.9" ] || { echo "FAIL trail pin: ${PINS[trail]}"; fail=1; }
  [ "${PINS[pad]:-}" = "v03.4.5" ] || { echo "FAIL pad pin: ${PINS[pad]}"; fail=1; }
  [ "${PINS[compact]:-}" = "v5.0.0" ] || { echo "FAIL compact pin: ${PINS[compact]}"; fail=1; }
  [ "${PINS[cmt]:-}" = "v6.0.0" ] || { echo "FAIL trailing-comment pin: ${PINS[cmt]}"; fail=1; }
  [ "${#PINS[@]}" -eq 5 ] || { echo "FAIL lenient pin count ${#PINS[@]} (want 5)"; fail=1; }
  exit $fail
' _ "$TMPD/pins.sh" || { echo "FAIL load_pins lenient-edge contract broke"; exit 1; }
# Empty-manifest edge: an existing-but-empty versions.toml loads zero pins.
: > "$TMPD/versions.toml"
bash -c '
  source "$1"
  load_pins
  [ "${#PINS[@]}" -eq 0 ] || { echo "FAIL empty manifest loaded ${#PINS[@]} pins"; exit 1; }
' _ "$TMPD/pins.sh" || { echo "FAIL load_pins empty-manifest edge broke"; exit 1; }
# Update-channel directives that are not pins must never reach PINS:
# branch=/channel=/url= lines are skipped by the pin grammar, so a
# mismatched release channel cannot be smuggled through versions.toml.
cat > "$TMPD/versions.toml" <<'EOF'
branch = "master"
channel = "nightly"
url = "https://example.invalid/x"
ref = "deadbeef"
oodac = "v1.2.3"
EOF
bash -c '
  source "$1"
  load_pins
  [ "${#PINS[@]}" -eq 1 ] || { echo "FAIL directive leak: ${#PINS[@]} pins"; declare -p PINS; exit 1; }
  [ "${PINS[oodac]:-}" = "v1.2.3" ] || { echo "FAIL oodac pin lost"; exit 1; }
  for k in branch channel url ref; do
    [ -z "${PINS[$k]:-}" ] || { echo "FAIL non-pin directive reached PINS: $k"; exit 1; }
  done
' _ "$TMPD/pins.sh" || { echo "FAIL versions.toml channel-directive refusal broke"; exit 1; }
# Plan v31: CLI contract dogfooding. --version prints and exits 0;
# unknown long options, bare positionals, unknown short options, and
# arguments after -- must all refuse fail-closed (rc!=0, no install).
out="$(bash install.sh --version 2>&1)"; rc=$?
[ $rc -eq 0 ] || { echo "FAIL --version rc=$rc"; exit 1; }
echo "$out" | grep -q 'openOODA installer' || { echo "FAIL --version output: $out"; exit 1; }
for bad in "--bogus-flag" "/etc/passwd" "-x" "-- --dry-run"; do
  rc=0
  bash install.sh $bad >/dev/null 2>&1 || rc=$?
  [ $rc -ne 0 ] || { echo "FAIL accepted hostile args: $bad"; exit 1; }
done
bash install.sh --bogus-flag 2>&1 | grep -q 'unknown option' || { echo "FAIL no unknown-option message"; exit 1; }
bash install.sh /etc/passwd 2>&1 | grep -q 'unexpected argument' || { echo "FAIL no unexpected-argument message"; exit 1; }
bash install.sh -- --dry-run 2>&1 | grep -q 'after --' || { echo "FAIL no post-dashdash message"; exit 1; }
# Round-trip/idempotence: two dry-runs must emit the identical install
# plan. Only self-reported wall-time and the live-fetched runtime
# version are volatile, so both are normalized before comparison.
flt_dry() { grep -v 'time:' | sed -E 's/runtime v[0-9.?]+/runtime vREL/'; }
env -i PATH=/usr/bin:/bin HOME="$HOME" OPENOODA_HOME="$TMPD/dh" bash install.sh --dry-run 2>&1 | flt_dry > "$TMPD/d1"
env -i PATH=/usr/bin:/bin HOME="$HOME" OPENOODA_HOME="$TMPD/dh" bash install.sh --dry-run 2>&1 | flt_dry > "$TMPD/d2"
cmp -s "$TMPD/d1" "$TMPD/d2" || { echo "FAIL dry-run plan not idempotent"; diff "$TMPD/d1" "$TMPD/d2" | head -10; exit 1; }
# Output-schema completeness: the dry-run plan must carry its required
# sections (prefix, Summary, simulated install, no-writes marker) and
# name every canonical component it would place.
for key in 'prefix:' 'Summary' 'simulated install' 'no files written'; do
  grep -qF "$key" "$TMPD/d1" || { echo "FAIL dry-run plan missing required section: $key"; exit 1; }
done
for comp in ooda oodac oodar oopm oolsp oomcp; do
  grep -qw "$comp" "$TMPD/d1" || { echo "FAIL dry-run plan missing component: $comp"; exit 1; }
done
# Version round-trip: the --version banner, the VERSION file, and the
# ooda.pkg manifest must all agree on the same release.
v_file="$(tr -d '[:space:]' < VERSION)"
bash install.sh --version 2>&1 | grep -qF "openOODA installer $v_file" || { echo "FAIL --version disagrees with VERSION ($v_file)"; exit 1; }
v_pkg="$(sed -n 's/^version=//p' ooda.pkg | head -1)"
[ "$v_pkg" = "$v_file" ] || { echo "FAIL ooda.pkg version $v_pkg != VERSION $v_file"; exit 1; }
# Multi-arch artifact resolution + fetch_and_verify tamper refusal.
# The real functions are lifted from install.sh and driven against a
# stubbed curl that serves fixtures, so the inline hash path (separate
# from sha256_check) is exercised behaviorally, not by grep.
FV="$TMPD/fv"; mkdir -p "$FV"
{ sed -n '/^declare -A BINARIES=/p;/^declare -A ASSETS=/p' install.sh
  sed -n '/^sums_expected() {/,/^}/p;/^asset_stem() {/,/^}/p;/^asset_names() {/,/^}/p;/^fetch_and_verify() {/,/^}/p' install.sh
} > "$FV/lib.sh"
grep -q '^fetch_and_verify() {' "$FV/lib.sh" && grep -q '^asset_names() {' "$FV/lib.sh" \
  || { echo "FAIL could not lift asset_names/fetch_and_verify from install.sh"; exit 1; }
an() { ( . "$FV/lib.sh"; export OS=linux ARCH="$2"; asset_names "$1" | tr '\n' ' ' ); }
[ "$(an oomcp arm64)" = "oomcp-linux-arm64 oomcp " ] || { echo "FAIL oomcp arm64 candidates: $(an oomcp arm64)"; exit 1; }
[ "$(an oodac x86_64)" = "oodac-linux-x86_64 oodac " ] || { echo "FAIL oodac x86_64 candidates: $(an oodac x86_64)"; exit 1; }
[ "$(an oodar arm64)" = "liboodar.a-linux-arm64 liboodar.a " ] || { echo "FAIL oodar arm64 candidates: $(an oodar arm64)"; exit 1; }
an oolsp arm64 | grep -q 'x86_64' && { echo "FAIL arm64 resolution leaked an x86_64 asset"; exit 1; }
an oolsp x86_64 | grep -q 'arm64' && { echo "FAIL x86_64 resolution leaked an arm64 asset"; exit 1; }
# fv_case <name> <binary-body> <sidecar-body|404> -> runs fetch_and_verify
fv_case() {
  local d="$FV/$1"; mkdir -p "$d/wd"; printf '%s' "$2" > "$d/srv_bin"
  if [ "$3" = "404" ]; then rm -f "$d/srv_sha"; else printf '%s\n' "$3" > "$d/srv_sha"; fi
  ( . "$FV/lib.sh"
    curl() { local o="" u="" a; while [ $# -gt 0 ]; do a="$1"; shift
        case "$a" in -o) o="$1"; shift;; -w|--connect-timeout|--max-time) shift;; -*) ;; *) u="$a";; esac; done
      case "$u" in *.sha256) [ -f "$d/srv_sha" ] || { printf 404; return 0; }; cp "$d/srv_sha" "$o";;
        *) cp "$d/srv_bin" "$o";; esac; printf 200; }
    fetch_and_verify "https://example.invalid/asset" "$d/dest" "$d/wd" )
}
good_hash="$(printf 'openooda-asset' | sha256sum | awk '{print $1}')"
fv_case ok 'openooda-asset' "$good_hash  asset"
[ "$(cat "$FV/ok/wd/vrc")" = "0" ] && [ -x "$FV/ok/dest" ] && [ ! -e "$FV/ok/dest.tmp.sha256" ] \
  || { echo "FAIL fetch_and_verify did not install a correctly signed artifact"; exit 1; }
fv_case tamper 'openooda-asseT' "$good_hash  asset"
[ "$(cat "$FV/tamper/wd/vrc")" = "mismatch" ] && [ ! -e "$FV/tamper/dest" ] \
  || { echo "FAIL fetch_and_verify installed a tampered artifact"; exit 1; }
fv_case upper 'openooda-asset' "$(printf '%s' "$good_hash" | tr 'a-f' 'A-F')  asset"
[ ! -e "$FV/upper/dest" ] || { echo "FAIL fetch_and_verify accepted an uppercase-corrupted digest"; exit 1; }
fv_case trunc 'openooda-asset' "${good_hash:0:63}  asset"
[ ! -e "$FV/trunc/dest" ] || { echo "FAIL fetch_and_verify accepted a truncated digest"; exit 1; }
fv_case blank 'openooda-asset' "   "
[ ! -e "$FV/blank/dest" ] || { echo "FAIL fetch_and_verify accepted a blank sidecar"; exit 1; }
fv_case nosig 'openooda-asset' 404
[ ! -e "$FV/nosig/dest" ] && [ ! -e "$FV/nosig/wd/vrc" ] \
  || { echo "FAIL fetch_and_verify installed an artifact with no sidecar"; exit 1; }
fv_case empty '' "$good_hash  asset"
[ ! -e "$FV/empty/dest" ] || { echo "FAIL fetch_and_verify installed an empty artifact"; exit 1; }
echo "PASS install 9.16 multi-arch-resolution+fetch-verify-tamper-refusal+fail-closed sha256+blackbox+toolchain+bash-rc+no-shadow+no-state-loss+opm-nonzero+on-disk-accept+from-source+from-source-dryrun-no-bootstrap+no-double-tui+selftest-corrupted-digests+pin-parsing-negative-trust+pin-grammar-adversarial+pin-lenient-edges+pin-empty-manifest+pin-channel-directive-refusal+cli-contract-refusals+dryrun-idempotence+dryrun-schema+version-roundtrip"
