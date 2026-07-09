#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

use_state
assert_eq "" "$(history_files)" "history_files empty when none"
assert_eq "" "$(newest_history)" "newest_history empty when none"

printf 'a\t/x\tA\n' | mk_hist "$STATE_DIR" 100 20260101T000000
printf 'b\t/y\tB\n' | mk_hist "$STATE_DIR" 100 20260101T000100
printf 'c\t/z\tC\n' | mk_hist "$STATE_DIR" 200 20260102T000000

# ascending order == chronological
assert_eq "100-20260101T000000
100-20260101T000100
200-20260102T000000" "$(history_files | while IFS= read -r f; do basename "$f" .tsv; done)" "history_files sorted ascending"

assert_eq "200-20260102T000000" "$(basename "$(newest_history)" .tsv)" "newest_history is last"
assert_eq "200" "$(boot_of_file "$(newest_history)")" "boot_of_file reads prefix"

finish
