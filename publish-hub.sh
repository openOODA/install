#!/usr/bin/env bash
# publish-hub.sh — thin exec shim delegating hub release publishing to core/publish/publish_hub.oo.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/.ooda-cache/publish-hub"
need_build=0
if [[ ! -x "$BIN" ]]; then
  need_build=1
else
  for src in "$DIR"/core/publish/*.oo; do
    if [[ "$src" -nt "$BIN" ]]; then need_build=1; break; fi
  done
fi
if [[ "$need_build" == "1" ]]; then
  env -u OODA_OODAR_ROOT -u OODA_OOSTD_ROOT make -C "$DIR" -s publish-bin
fi
exec env -u OODA_OODAR_ROOT -u OODA_OOSTD_ROOT OODA_NO_JAIL=1 "$BIN" "$@"
