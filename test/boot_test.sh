#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

# _parse_boottime extracts the sec field, not usec.
got="$(printf '{ sec = 1783594214, usec = 586840 } Thu Jul  9 13:50:14 2026\n' | _parse_boottime)"
assert_eq "1783594214" "$got" "_parse_boottime extracts sec"

# current_boot honors the override.
CCSR_BOOT_OVERRIDE=999 assert_eq "999" "$(CCSR_BOOT_OVERRIDE=999 current_boot)" "current_boot uses override"

# now_ts honors the override and matches the timestamp shape otherwise.
assert_eq "20260709T135900" "$(CCSR_NOW_OVERRIDE=20260709T135900 now_ts)" "now_ts uses override"
case "$(now_ts)" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ok=1 ;;
  *) ok=0 ;;
esac
assert_eq "1" "$ok" "now_ts default shape is YYYYMMDDTHHMMSS"

finish
