#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

count_hist() { history_files | grep -c . ; }

# Upgrade path: pre-existing snapshot.tsv, empty history -> seeded once.
use_state
CCSR_BOOT_OVERRIDE=100
printf 'old\t/o\tOLD\n' > "$SNAPSHOT"
CCSR_NOW_OVERRIDE=20260101T120000 seed_history_from_snapshot
assert_eq "1" "$(count_hist)" "seed creates one entry from snapshot.tsv"
assert_eq "100" "$(boot_of_file "$(newest_history)")" "seed tagged with current boot"

# Seeding is idempotent (history non-empty -> no-op).
CCSR_NOW_OVERRIDE=20260101T120100 seed_history_from_snapshot
assert_eq "1" "$(count_hist)" "seed is idempotent"

# record_snapshot: seed + append + prune in one call.
use_state
export CCSR_HISTORY_LIMIT=50 CCSR_KEEP_BOOTS=10
CCSR_BOOT_OVERRIDE=200
cand="$(mktemp)"; printf 'x\t/x\tX\n' > "$cand"
CCSR_NOW_OVERRIDE=20260102T120000 record_snapshot "$cand"
assert_eq "1" "$(count_hist)" "record_snapshot appends a live capture"
unset CCSR_HISTORY_LIMIT CCSR_KEEP_BOOTS

finish
