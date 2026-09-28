#!/bin/bash
# install e2e — real install into a temp HOME, then prove it works.
# Asserts: exit 0, all 8 binaries present + SHA-256 verified per the
# summary, every binary answers --help, and --no-modify-shell leaves
# shell rc files untouched. Needs network (downloads release binaries).
set -u
cd "$(dirname "$0")/.." || exit 1
THOME="$(mktemp -d /tmp/e2ehome.XXXXXX)" || exit 1
trap 'rm -rf "$THOME"' EXIT
HOME="$THOME" OPENOODA_HOME="$THOME/.openooda" XDG_CONFIG_HOME="$THOME/.config" \
  bash install.sh --yes --no-modify-shell > "$THOME/install.log" 2>&1
rc=$?
test "$rc" -eq 0 || { echo "FAIL installer exit=$rc"; tail -5 "$THOME/install.log"; exit 1; }
grep -q "SHA-256 verified" "$THOME/install.log" || { echo "FAIL no SHA-256 verified line"; exit 1; }
grep -q "skipped (--no-modify-shell)" "$THOME/install.log" || { echo "FAIL summary misreports rc skip"; exit 1; }
for b in ooda cli oodac opm lsp mcp tui; do
  test -x "$THOME/.openooda/bin/$b" || { echo "FAIL missing bin $b"; exit 1; }
  "$THOME/.openooda/bin/$b" --help >/dev/null 2>&1 || { echo "FAIL $b --help"; exit 1; }
done
test -f "$THOME/.openooda/bin/liboodar.a" || { echo "FAIL missing liboodar.a"; exit 1; }
for rc in .bashrc .bash_profile .zshrc; do
  test ! -e "$THOME/$rc" || { echo "FAIL rc file written: $rc"; exit 1; }
done
echo "PASS install e2e (temp HOME, 7 binaries --help, rc untouched)"
