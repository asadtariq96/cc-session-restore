#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

use_state
printf 's1\t/a\tAlpha\n' | mk_hist "$STATE_DIR" 100 20260101T130000
printf 'n1\t/new\tGamma\n' | mk_hist "$STATE_DIR" 200 20260102T140000
CCSR_BOOT_OVERRIDE=200

# Empty stdin -> default (prior-boot) entry.
got="$(printf '' | _pick_menu 2>/dev/null)"
assert_eq "100-20260101T130000" "$(basename "$got" .tsv)" "menu default = prior-boot"

# Explicit index 1 (newest-first) -> current-boot entry.
got="$(printf '1\n' | _pick_menu 2>/dev/null)"
assert_eq "200-20260102T140000" "$(basename "$got" .tsv)" "menu index 1 = newest"

finish
