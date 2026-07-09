#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

# Scenario: reboot then opened 1 fresh session. Current boot = 200.
use_state
printf 's1\t/a\tA\ns2\t/b\tB\ns3\t/c\tC\ns4\t/d\tD\ns5\t/e\tE\n' | mk_hist "$STATE_DIR" 100 20260101T130000
printf 'n1\t/new\tNEW\n' | mk_hist "$STATE_DIR" 200 20260101T140000
CCSR_BOOT_OVERRIDE=200
assert_eq "100-20260101T130000" "$(basename "$(select_default)" .tsv)" "picks pre-reboot 5-session set, not current-boot 1"

# Scenario: no reboot since first snapshot -> newest overall.
use_state
printf 'a\t/a\tA\n' | mk_hist "$STATE_DIR" 100 20260101T130000
printf 'a\t/a\tA\nb\t/b\tB\n' | mk_hist "$STATE_DIR" 100 20260101T131000
CCSR_BOOT_OVERRIDE=100
assert_eq "100-20260101T131000" "$(basename "$(select_default)" .tsv)" "no reboot -> newest overall"

# Scenario: two prior boots + current -> newest of the most recent prior boot.
use_state
printf 'a\t/a\tA\n' | mk_hist "$STATE_DIR" 100 20260101T130000
printf 'b\t/b\tB\n' | mk_hist "$STATE_DIR" 200 20260102T130000
printf 'c\t/c\tC\n' | mk_hist "$STATE_DIR" 200 20260102T131000
printf 'd\t/d\tD\n' | mk_hist "$STATE_DIR" 300 20260103T130000
CCSR_BOOT_OVERRIDE=300
assert_eq "200-20260102T131000" "$(basename "$(select_default)" .tsv)" "picks newest of most-recent prior boot"

# Scenario: empty history -> empty.
use_state
CCSR_BOOT_OVERRIDE=100
assert_eq "" "$(select_default)" "empty history -> empty"

finish
