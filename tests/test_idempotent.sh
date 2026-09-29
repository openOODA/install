#!/bin/bash
# install idempotency — run the installer twice into the same temp HOME.
# Proves the documented "Re-run is safe" claim: second run exits 0 and the
# installed binary set is byte-identical (same files, same SHA-256).
# Needs network (downloads release binaries), like test_e2e_install.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
THOME="$(mktemp -d /tmp/e2eidem.XXXXXX)" || exit 1
trap 'rm -rf "$THOME"' EXIT
run_install() {
  HOME="$THOME" OPENOODA_HOME="$THOME/.openooda" XDG_CONFIG_HOME="$THOME/.config" \
    bash install.sh --yes --no-modify-shell > "$THOME/$1" 2>&1
}
snapshot() {
  (cd "$THOME/.openooda/bin" && for b in ooda cli oodac opm lsp mcp tui; do
    test -x "$b" || { echo "FAIL missing bin $b ($1)"; exit 1; }
    sha256sum "$b"
  done; test -f liboodar.a || { echo "FAIL missing liboodar.a ($1)"; exit 1; }
  sha256sum liboodar.a) > "$THOME/$1"
}
run_install install1.log
rc1=$?
test "$rc1" -eq 0 || { echo "FAIL first install exit=$rc1"; tail -5 "$THOME/install1.log"; exit 1; }
snapshot snap1.txt || exit 1
run_install install2.log
rc2=$?
test "$rc2" -eq 0 || { echo "FAIL second install exit=$rc2"; tail -5 "$THOME/install2.log"; exit 1; }
snapshot snap2.txt || exit 1
diff -u "$THOME/snap1.txt" "$THOME/snap2.txt" || { echo "FAIL reinstall changed installed binaries"; exit 1; }
echo "PASS install idempotent (two runs, identical binaries)"
