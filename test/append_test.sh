#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

count_hist() { history_files | grep -c . ; }

# Non-empty candidate creates one entry and refreshes snapshot.tsv.
use_state
CCSR_BOOT_OVERRIDE=100
cand="$(mktemp)"; printf 'a\t/a\tA\n' > "$cand"
CCSR_NOW_OVERRIDE=20260101T130000 append_snapshot "$cand"
assert_eq "1" "$(count_hist)" "first append creates one entry"
assert_eq "a	/a	A" "$(cat "$SNAPSHOT")" "snapshot.tsv refreshed"

# Identical body, same boot -> deduped (no new file).
CCSR_NOW_OVERRIDE=20260101T130100 append_snapshot "$cand"
assert_eq "1" "$(count_hist)" "identical body same boot deduped"

# Changed body -> new entry.
printf 'a\t/a\tA\nb\t/b\tB\n' > "$cand"
CCSR_NOW_OVERRIDE=20260101T130200 append_snapshot "$cand"
assert_eq "2" "$(count_hist)" "changed body appends"

# Same body but new boot -> new entry (per-boot marker must exist).
printf 'a\t/a\tA\nb\t/b\tB\n' > "$cand"
CCSR_BOOT_OVERRIDE=200
CCSR_NOW_OVERRIDE=20260102T130000 append_snapshot "$cand"
assert_eq "3" "$(count_hist)" "same body new boot appends"

# Empty candidate -> no-op, snapshot.tsv unchanged.
: > "$cand"
before="$(cat "$SNAPSHOT")"
CCSR_NOW_OVERRIDE=20260102T140000 append_snapshot "$cand"
assert_eq "3" "$(count_hist)" "empty candidate does not append"
assert_eq "$before" "$(cat "$SNAPSHOT")" "empty candidate does not touch snapshot.tsv"

finish
