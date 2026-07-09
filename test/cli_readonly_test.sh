#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"

# Drive the real binary (read-only paths must not require macOS).
setup() {
  base="$(mktemp -d)"; sd="$base/cc-session-restore"; mkdir -p "$sd/history"
  printf 's1\t/a\tAlpha\ns2\t/b\tBeta\n' > "$sd/history/100-20260101T130000.tsv"
  printf 'n1\t/new\tGamma\n' > "$sd/history/200-20260102T140000.tsv"
}
run() { XDG_STATE_HOME="$base" CCSR_BOOT_OVERRIDE=200 "$BIN" "$@"; }

setup
# --list shows both entries and marks the prior-boot default.
out="$(run restore --list)"
assert_contains "$out" "2026-01-01 13:00" "list shows prior-boot time"
assert_contains "$out" "2026-01-02 14:00" "list shows current-boot time"
assert_contains "$out" "prior-boot" "list marks prior-boot"

# --show by index 1 (newest-first) shows the current-boot session.
out="$(run restore --show 1)"
assert_contains "$out" "claude --resume n1" "show index 1 = newest"

# --show by index 2 shows the prior-boot sessions.
out="$(run restore --show 2)"
assert_contains "$out" "claude --resume s1" "show index 2 = older"
assert_contains "$out" "claude --resume s2" "show lists all sessions in the set"

# --show by stem substring works too.
out="$(run restore --show 100-20260101T130000)"
assert_contains "$out" "claude --resume s1" "show by stem id"

# bad id fails nonzero.
if run restore --show 999 >/dev/null 2>&1; then
  assert_eq "fail" "ok" "bad id should exit nonzero"
else
  assert_eq "ok" "ok" "bad id exits nonzero"
fi

finish
