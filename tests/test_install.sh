#!/bin/bash
# install 9.1 — sha256, blackbox, and harness auto-wire
set -e
grep -q "sha256" install.sh || { echo "FAIL no sha256"; exit 1; }
grep -q "blackbox" install.sh || { echo "FAIL no blackbox"; exit 1; }
grep -q "BINARIES.*blackbox" install.sh || { echo "FAIL no blackbox binary"; exit 1; }
grep -q "wire_harnesses" install.sh || { echo "FAIL no harness wire"; exit 1; }
grep -q "detect_harnesses" install.sh || { echo "FAIL no harness detect"; exit 1; }
grep -q "antigravity-cli" install.sh || { echo "FAIL no antigravity-cli probe"; exit 1; }
grep -q "opencode" install.sh || { echo "FAIL no opencode probe"; exit 1; }
grep -q "muse" install.sh || { echo "FAIL no muse probe"; exit 1; }
grep -q "mistral-vibe" install.sh || { echo "FAIL no mistral-vibe stub"; exit 1; }
grep -q "OODA_COMPILER" install.sh || { echo "FAIL no OODA_COMPILER env"; exit 1; }
grep -q "OODA_FS_READDIR" install.sh || { echo "FAIL no OODA_FS_READDIR"; exit 1; }
grep -q "TOTAL=12" install.sh || { echo "FAIL TOTAL not 12 (harness step missing)"; exit 1; }
echo "PASS install 9.1 sha256+blackbox+harnesses"
