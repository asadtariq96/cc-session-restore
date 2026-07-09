#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"

base="$(mktemp -d)"; sd="$base/cc-session-restore"; mkdir -p "$sd/history"
printf 's1\t/a\tAlpha\n' > "$sd/history/100-20260101T130000.tsv"
printf 'n1\t/new\tGamma\n' > "$sd/history/200-20260102T140000.tsv"

# status is macOS-gated for the agent line; run the helper directly instead.
# shellcheck source=/dev/null
source "$BIN"
STATE_DIR="$sd"; SNAPSHOT="$sd/snapshot.tsv"; CCSR_BOOT_OVERRIDE=200
out="$(cmd_status 2>/dev/null || true)"
assert_contains "$out" "history:" "status shows history line"
assert_contains "$out" "2 snapshot" "status counts history"
assert_contains "$out" "restore target:" "status shows default target"
assert_contains "$out" "100-20260101T130000" "target = prior-boot default"

finish
