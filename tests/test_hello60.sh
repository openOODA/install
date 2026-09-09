#!/usr/bin/env bash
# Task 1: the 60-second hello world (host half).
# Launches a fresh container and runs test_hello60_inner.sh in it.
#
#   ./tests/test_hello60.sh                 # dry check (no container)
#   HELLO60_LIVE=1 ./tests/test_hello60.sh  # real run (needs podman/docker + network)
#
# Override for local installer testing (skips the URL):
#   HELLO60_LIVE=1 INSTALL_MNT=/path/to/install/repo ./tests/test_hello60.sh
# Override the base image (must provide a POSIX sh; curl is installed by the test):
#   HELLO60_IMAGE=docker.io/library/ubuntu:24.04 ./tests/test_hello60.sh
set -u
cd "$(dirname "$0")"
RT=""
command -v podman >/dev/null 2>&1 && RT=podman
[[ -z "$RT" ]] && command -v docker >/dev/null 2>&1 && RT=docker
IMAGE="${HELLO60_IMAGE:-docker.io/library/ubuntu:24.04}"
BUDGET="${BUDGET:-60}"

if [[ "${HELLO60_LIVE:-0}" != "1" ]]; then
  # Static contract checks only: both halves present, inner asserts the
  # exact acceptance (zero env, zero sourcing, budget).
  grep -q 'env -i' test_hello60_inner.sh || { echo "FAIL inner must use env -i"; exit 1; }
  grep -q 'command -v ooda' test_hello60_inner.sh || { echo "FAIL inner must assert PATH"; exit 1; }
  grep -q 'BUDGET' test_hello60_inner.sh || { echo "FAIL inner must enforce budget"; exit 1; }
  grep -qE '(^|[;&| ])source( |$)' test_hello60_inner.sh && { echo "FAIL inner must not source rc files"; exit 1; }
  echo "PASS hello60 contract (static). Set HELLO60_LIVE=1 for the container run."
  exit 0
fi

[[ -n "$RT" ]] || { echo "FAIL no podman/docker"; exit 1; }
PREP="apt-get update -qq && apt-get install -y -qq curl ca-certificates"
# SELinux (enforcing hosts): mounts need a relabeled STAGE of copies so the
# repo itself is never relabeled.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp test_hello60_inner.sh "$STAGE/t.sh"
if [[ -n "${INSTALL_MNT:-}" ]]; then
  # Test a LOCAL install.sh: stage a copy, run the file (same code path as curl|bash).
  cp "$INSTALL_MNT/install.sh" "$STAGE/install.sh"
  cp "$INSTALL_MNT/VERSION" "$STAGE/VERSION" 2>/dev/null || true
  cp "$INSTALL_MNT/versions.toml" "$STAGE/versions.toml" 2>/dev/null || true
  $RT run --rm -v "$STAGE:/stage:z" \
    -e BUDGET="$BUDGET" -e "INSTALL_CMD=bash /stage/install.sh" \
    "$IMAGE" bash -c "$PREP >/dev/null 2>&1 && bash /stage/t.sh"
else
  $RT run --rm -v "$STAGE:/stage:z" \
    -e BUDGET="$BUDGET" \
    "$IMAGE" bash -c "$PREP >/dev/null 2>&1 && bash /stage/t.sh"
fi
