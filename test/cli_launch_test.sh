#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"

setup() {
  base="$(mktemp -d)"; sd="$base/cc-session-restore"; mkdir -p "$sd/history"
  printf 's1\t/a\tAlpha\ns2\t/b\tBeta\n' > "$sd/history/100-20260101T130000.tsv"
  printf 'n1\t/new\tGamma\n' > "$sd/history/200-20260102T140000.tsv"
}
run() { XDG_STATE_HOME="$base" CCSR_BOOT_OVERRIDE=200 "$BIN" "$@"; }

setup
# Default (non-tty stdin/stdout in CI) + dry-run -> prior-boot set.
out="$(run restore --dry-run </dev/null)"
assert_contains "$out" "claude --resume s1" "default dry-run = prior-boot set"
assert_contains "$out" "claude --resume s2" "default dry-run lists all"
case "$out" in *"claude --resume n1"*) hasn=1 ;; *) hasn=0 ;; esac
assert_eq "0" "$hasn" "default excludes current-boot session"

# --latest -> newest overall.
out="$(run restore --latest --dry-run </dev/null)"
assert_contains "$out" "claude --resume n1" "--latest = newest overall"

# --snapshot by index 2 -> older set.
out="$(run restore --snapshot 2 --dry-run </dev/null)"; rc=$?
assert_contains "$out" "claude --resume s1" "--snapshot 2 = older set"

# dry-run must not require macOS (would have died otherwise on Linux).
assert_eq "0" "$rc" "dry-run exits 0 on non-macOS"

finish
