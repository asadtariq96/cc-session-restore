#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

count_hist() { history_files | grep -c . ; }

# Churn in the current boot must NOT evict the prior-boot entry.
use_state
export CCSR_HISTORY_LIMIT=5 CCSR_KEEP_BOOTS=10
# one prior-boot entry (the set we must keep):
printf 'PRE\t/pre\tPRE\n' | mk_hist "$STATE_DIR" 100 20260101T120000
# 8 current-boot entries (churn), each distinct:
i=0
while [ "$i" -lt 8 ]; do
  printf 'cur%s\t/c\tC\n' "$i" | mk_hist "$STATE_DIR" 200 "20260102T13000$i"
  i=$((i + 1))
done
assert_eq "9" "$(count_hist)" "setup: 9 entries"
prune_history
# Keep newest 5 (all boot 200) + newest per boot for last 10 boots
# (boot 100 newest = PRE, boot 200 newest already in newest-5) -> PRE survives.
assert_eq "1" "$(history_files | grep -c '/100-')" "prior-boot entry protected from churn"
# Only newest 5 of boot 200 remain (8 -> 5 kept, 3 pruned).
assert_eq "5" "$(history_files | grep -c '/200-')" "current-boot trimmed to limit"
unset CCSR_HISTORY_LIMIT CCSR_KEEP_BOOTS

# Under the limit -> nothing pruned.
use_state
export CCSR_HISTORY_LIMIT=50 CCSR_KEEP_BOOTS=10
printf 'a\t/a\tA\n' | mk_hist "$STATE_DIR" 100 20260101T120000
printf 'b\t/b\tB\n' | mk_hist "$STATE_DIR" 100 20260101T120100
prune_history
assert_eq "2" "$(count_hist)" "under limit keeps all"
unset CCSR_HISTORY_LIMIT CCSR_KEEP_BOOTS

finish
