#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$here"/*_test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  bash "$t" || rc=1
done
exit "$rc"
