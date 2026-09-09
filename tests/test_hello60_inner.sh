#!/usr/bin/env bash
# Task 1: the 60-second hello world (container-side half).
# Runs INSIDE a fresh container. See test_hello60.sh (host half).
#
# Contract: base image provides curl only. Everything else — gcc, git,
# std, oodar sources, PATH — must come from install.sh with zero user
# config. Then a hello-world compiles and runs with zero OODA_* env vars,
# zero rc sourcing, end to end within BUDGET seconds of install start.
#
# Override INSTALL_CMD to test a local install.sh instead of the URL, e.g.:
#   INSTALL_CMD="bash /mnt/install.sh" BUDGET=300 ./test_hello60_inner.sh
set -u
BUDGET="${BUDGET:-60}"
INSTALL_CMD="${INSTALL_CMD:-curl -fsSL https://openooda.org/install.sh | bash}"
START=$(date +%s)
say() { printf '[hello60] %s\n' "$*"; }
die() { say "FAIL: $*"; exit 1; }
elapsed() { echo $(( $(date +%s) - START )); }

say "install start (budget ${BUDGET}s)"
# shellcheck disable=SC2094
bash -c "$INSTALL_CMD" 2>&1 | tail -n 4
say "installer done at $(elapsed)s"

# Zero tribal knowledge from here: no sourcing rc files, no env exports,
# no OODA_* vars. The toolchain must work in this bare shell.
command -v ooda >/dev/null 2>&1 || die "ooda not on PATH without rc sourcing ($(elapsed)s)"
command -v oodac >/dev/null 2>&1 || die "oodac not on PATH without rc sourcing ($(elapsed)s)"

mkdir -p /tmp/hello && cd /tmp/hello || die "no workdir"
cat > main.oo <<'OO'
// # Hello fixture — Task 1 acceptance program
//
// Logline: Minimal runnable program for the 60-second hello-world test.
//
// Setup: No imports, no caps, builtin println only.
//
// Beats:
//   1. Print the acceptance line and return 0.

pub fn main() -> Int {
    println("hello, sovereign world")
    return 0
}
OO
env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" ooda run main.oo > out.txt 2>&1 \
  || die "ooda run failed ($(elapsed)s): $(head -n 10 out.txt)"
grep -q "hello, sovereign world" out.txt \
  || die "wrong output ($(elapsed)s): $(head -n 10 out.txt)"

END=$(elapsed)
say "hello-world OK at ${END}s (budget ${BUDGET}s)"
[[ "$END" -le "$BUDGET" ]] || die "over budget: ${END}s > ${BUDGET}s"
say "PASS"
