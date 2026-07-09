# test/helpers.bash — tiny assert + fixture helpers. No external deps. Bash 3.2 safe.
# shellcheck shell=bash
BIN="${BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/cc-session-restore}"

_tests_run=0
_tests_failed=0

assert_eq() { # want got [msg]
  _tests_run=$((_tests_run + 1))
  if [ "$1" != "$2" ]; then
    _tests_failed=$((_tests_failed + 1))
    printf 'FAIL: %s\n  want: [%s]\n  got:  [%s]\n' "${3:-}" "$1" "$2" >&2
  fi
}

assert_contains() { # haystack needle [msg]
  _tests_run=$((_tests_run + 1))
  case "$1" in
    *"$2"*) : ;;
    *) _tests_failed=$((_tests_failed + 1))
       printf 'FAIL: %s\n  [%s] not found in output:\n%s\n' "${3:-}" "$2" "$1" >&2 ;;
  esac
}

# Fresh fixture state dir; overrides the script's globals for the current test.
use_state() {
  local base
  base="$(mktemp -d)"
  STATE_DIR="$base/cc-session-restore"
  SNAPSHOT="$STATE_DIR/snapshot.tsv"
  mkdir -p "$STATE_DIR/history"
}

# Write a history file. Body comes from stdin.
mk_hist() { # state_dir boot ts
  cat > "$1/history/$2-$3.tsv"
}

finish() {
  printf '%d run, %d failed\n' "$_tests_run" "$_tests_failed"
  [ "$_tests_failed" -eq 0 ]
}
