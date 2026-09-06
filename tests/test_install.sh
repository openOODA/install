#!/bin/bash
# install 9.1 — sha256 and blackbox component present
set -e
grep -q "sha256" install.sh || { echo "FAIL no sha256"; exit 1; }
grep -q "blackbox" install.sh || { echo "FAIL no blackbox"; exit 1; }
grep -q "BINARIES.*blackbox" install.sh || { echo "FAIL no blackbox binary"; exit 1; }
echo "PASS install 9.1 sha256+blackbox"
