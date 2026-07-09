# Multi-session Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a history of session snapshots so a reboot-aware `restore` can reopen the exact set of sessions that were open before the last reboot — not just the most recent (possibly smaller) snapshot.

**Architecture:** Replace the single-slot `snapshot.tsv` with an append-only `history/` directory of boot-time-tagged TSV files. `snapshot` appends only when the open-session set changes and never on an empty capture. `restore` defaults to the newest set from a boot other than the current one, and exposes `--list`/`--show`/`--snapshot`/`--latest` plus an optional fzf picker (numbered-menu fallback).

**Tech Stack:** Bash (must run on macOS's Bash 3.2), coreutils (`sed`, `grep`, `awk`, `sort`, `cmp`, `date`, `mktemp`), `sysctl` for boot time, `osascript`/iTerm2 for launch, optional `fzf`. Tests are plain Bash sourced on Linux CI.

## Global Constraints

- **Bash 3.2 compatible.** No `mapfile`, no `declare -A`/associative arrays, no `${var,,}`. Indexed arrays and process substitution are OK.
- **Single script.** All runtime logic lives in `bin/cc-session-restore`. No new required runtime dependency; `fzf` is strictly optional.
- **Restricted PATH.** Runtime `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and `LC_ALL=C` (set at top of script). Only tools in those dirs may be used.
- **macOS-only** for `snapshot`, `agent`, and the actual launch. `restore --list`/`--show`/`--dry-run` must NOT require macOS.
- **shellcheck clean.** `shellcheck bin/cc-session-restore install.sh` must pass (existing CI job). Split declaration+assignment to avoid SC2155 (`local x; x="$(...)"`).
- **TSV body format unchanged:** `sessionId \t cwd \t title`, tab-separated, read with `IFS=$'\t' read -r sid cwd title`.
- **Env vars:** `CCSR_HISTORY_LIMIT` (default `50`), `CCSR_KEEP_BOOTS` (default `10`), and testing overrides `CCSR_BOOT_OVERRIDE`, `CCSR_NOW_OVERRIDE`.
- **Version:** bump `0.1.0` → `0.2.0` in both `VERSION` and the in-script `VERSION=`.
- History filename format: `<boot_epoch_sec>-<UTC ts YYYYMMDDTHHMMSS>.tsv` (fixed width ⇒ lexicographic sort == chronological).

---

### Task 1: Test harness, sourceable script, boot/time primitives

**Files:**
- Modify: `bin/cc-session-restore` (source-guard at bottom; add `_parse_boottime`, `current_boot`, `now_ts`)
- Create: `test/helpers.bash`
- Create: `test/run.sh`
- Create: `test/boot_test.sh`

**Interfaces:**
- Produces: `_parse_boottime` (stdin → boot epoch on stdout), `current_boot` (→ boot epoch; honors `$CCSR_BOOT_OVERRIDE`), `now_ts` (→ `YYYYMMDDTHHMMSS`; honors `$CCSR_NOW_OVERRIDE`).
- Produces (test harness): `assert_eq want got [msg]`, `assert_contains haystack needle [msg]`, `use_state` (fresh fixture STATE_DIR, sets `STATE_DIR`/`SNAPSHOT`), `mk_hist state boot ts` (body on stdin), `finish` (prints summary, returns nonzero on failure). Global `BIN` points at the script.

- [ ] **Step 1: Write the failing test**

Create `test/helpers.bash`:

```bash
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
```

Create `test/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$here"/*_test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  bash "$t" || rc=1
done
exit "$rc"
```

Create `test/boot_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/helpers.bash"
# shellcheck source=/dev/null
source "$BIN"

# _parse_boottime extracts the sec field, not usec.
got="$(printf '{ sec = 1783594214, usec = 586840 } Thu Jul  9 13:50:14 2026\n' | _parse_boottime)"
assert_eq "1783594214" "$got" "_parse_boottime extracts sec"

# current_boot honors the override.
CCSR_BOOT_OVERRIDE=999 assert_eq "999" "$(CCSR_BOOT_OVERRIDE=999 current_boot)" "current_boot uses override"

# now_ts honors the override and matches the timestamp shape otherwise.
assert_eq "20260709T135900" "$(CCSR_NOW_OVERRIDE=20260709T135900 now_ts)" "now_ts uses override"
case "$(now_ts)" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ok=1 ;;
  *) ok=0 ;;
esac
assert_eq "1" "$ok" "now_ts default shape is YYYYMMDDTHHMMSS"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/boot_test.sh`
Expected: FAIL — sourcing `$BIN` runs `main` (no source-guard yet) and `_parse_boottime`/`current_boot`/`now_ts` are undefined.

- [ ] **Step 3: Add the source-guard and primitives to `bin/cc-session-restore`**

Change the very last line from `main "$@"` to:

```bash
# Only run when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

Add these functions just after the `json_num` helper (around line 43):

```bash
# --- boot / time primitives --------------------------------------------------
_parse_boottime() { sed -E 's/^\{ sec = ([0-9]+).*/\1/'; }

current_boot() {
  if [ -n "${CCSR_BOOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$CCSR_BOOT_OVERRIDE"
  else
    sysctl -n kern.boottime 2>/dev/null | _parse_boottime
  fi
}

now_ts() { printf '%s\n' "${CCSR_NOW_OVERRIDE:-$(date -u +%Y%m%dT%H%M%S)}"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/boot_test.sh`
Expected: PASS — `4 run, 0 failed`.

Also confirm nothing else broke: `shellcheck bin/cc-session-restore install.sh` → no output.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/helpers.bash test/run.sh test/boot_test.sh
git commit -m "test: harness + sourceable script + boot/time primitives"
```

---

### Task 2: History file helpers

**Files:**
- Modify: `bin/cc-session-restore` (add `history_files`, `newest_history`, `boot_of_file`)
- Create: `test/history_test.sh`

**Interfaces:**
- Consumes: `$STATE_DIR`.
- Produces: `history_files` (→ sorted-ascending list of `$STATE_DIR/history/*.tsv`, empty if none), `newest_history` (→ last of that list, empty if none), `boot_of_file path` (→ boot prefix of a history filename).

- [ ] **Step 1: Write the failing test**

Create `test/history_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/history_test.sh`
Expected: FAIL — `history_files` etc. undefined.

- [ ] **Step 3: Add the helpers to `bin/cc-session-restore`**

Add after the boot primitives:

```bash
# --- history helpers ---------------------------------------------------------
history_files() {
  local f
  for f in "$STATE_DIR"/history/*.tsv; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
  done | sort
}

newest_history() { history_files | tail -n 1; }

boot_of_file() { # path -> boot prefix
  local b
  b="$(basename "$1")"
  printf '%s\n' "${b%%-*}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/history_test.sh`
Expected: PASS — `5 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/history_test.sh
git commit -m "feat: history file helpers (list/newest/boot-of)"
```

---

### Task 3: Reboot-aware selection (`select_default`)

**Files:**
- Modify: `bin/cc-session-restore` (add `select_default`)
- Create: `test/select_test.sh`

**Interfaces:**
- Consumes: `history_files`, `current_boot`, `boot_of_file`.
- Produces: `select_default` (→ path of the newest snapshot whose boot ≠ current boot; else newest overall; else empty).

- [ ] **Step 1: Write the failing test**

Create `test/select_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/select_test.sh`
Expected: FAIL — `select_default` undefined.

- [ ] **Step 3: Add `select_default` to `bin/cc-session-restore`**

Add after the history helpers:

```bash
# --- selection ---------------------------------------------------------------
# Default restore target: newest snapshot from a boot other than the current
# one (i.e. the set open before this reboot); else the newest overall.
select_default() {
  local cur f newest="" last_other=""
  cur="$(current_boot)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    newest="$f"
    if [ "$(boot_of_file "$f")" != "$cur" ]; then
      last_other="$f"
    fi
  done < <(history_files)
  if [ -n "$last_other" ]; then
    printf '%s\n' "$last_other"
  elif [ -n "$newest" ]; then
    printf '%s\n' "$newest"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/select_test.sh`
Expected: PASS — `4 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/select_test.sh
git commit -m "feat: reboot-aware default selection"
```

---

### Task 4: Append with dedup (`append_snapshot`)

**Files:**
- Modify: `bin/cc-session-restore` (add `append_snapshot`)
- Create: `test/append_test.sh`

**Interfaces:**
- Consumes: `current_boot`, `now_ts`, `newest_history`, `boot_of_file`.
- Produces: `append_snapshot CANDIDATE` — if `CANDIDATE` is non-empty, append `history/<boot>-<now_ts>.tsv` **unless** the newest history file has the same body AND same boot (dedup); always refresh `snapshot.tsv` from a non-empty candidate; empty candidate is a no-op.

- [ ] **Step 1: Write the failing test**

Create `test/append_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/append_test.sh`
Expected: FAIL — `append_snapshot` undefined.

- [ ] **Step 3: Add `append_snapshot` to `bin/cc-session-restore`**

Add after `select_default`:

```bash
# Append CANDIDATE to history unless it duplicates the newest same-boot entry.
# Always refresh snapshot.tsv from a non-empty candidate. Empty = no-op.
append_snapshot() { # $1 = candidate tsv (may be empty/zero-length)
  local cand="$1" cur newest ts dest do_append=1
  [ -s "$cand" ] || return 0
  cur="$(current_boot)"
  newest="$(newest_history)"
  if [ -n "$newest" ] && cmp -s "$cand" "$newest" \
     && [ "$(boot_of_file "$newest")" = "$cur" ]; then
    do_append=0
  fi
  if [ "$do_append" = 1 ]; then
    ts="$(now_ts)"
    dest="$STATE_DIR/history/$cur-$ts.tsv"
    mkdir -p "$STATE_DIR/history"
    cp "$cand" "$dest"
  fi
  cp "$cand" "$SNAPSHOT"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/append_test.sh`
Expected: PASS — `6 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/append_test.sh
git commit -m "feat: append snapshots to history with dedup"
```

---

### Task 5: Retention (`prune_history`)

**Files:**
- Modify: `bin/cc-session-restore` (add `prune_history`)
- Create: `test/prune_test.sh`

**Interfaces:**
- Consumes: `history_files`, `boot_of_file`, `$CCSR_HISTORY_LIMIT`, `$CCSR_KEEP_BOOTS`.
- Produces: `prune_history` — keeps the newest `CCSR_HISTORY_LIMIT` (default 50) entries AND the newest entry of each of the last `CCSR_KEEP_BOOTS` (default 10) distinct boots; deletes the rest. Bash 3.2 safe (temp files, no associative arrays).

- [ ] **Step 1: Write the failing test**

Create `test/prune_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/prune_test.sh`
Expected: FAIL — `prune_history` undefined.

- [ ] **Step 3: Add `prune_history` to `bin/cc-session-restore`**

Add after `append_snapshot`:

```bash
# Keep newest CCSR_HISTORY_LIMIT entries plus the newest entry of each of the
# last CCSR_KEEP_BOOTS boots. Bash-3.2 safe: uses temp files, not hash sets.
prune_history() {
  local limit="${CCSR_HISTORY_LIMIT:-50}" keepboots="${CCSR_KEEP_BOOTS:-10}"
  local all keep total boots b nf f
  all="$(mktemp)"; keep="$(mktemp)"
  history_files > "$all"
  total="$(grep -c . "$all" 2>/dev/null || printf '0')"
  if [ "$total" -le "$limit" ]; then
    rm -f "$all" "$keep"
    return 0
  fi
  # newest `limit`
  tail -n "$limit" "$all" >> "$keep"
  # last `keepboots` distinct boots (ascending), newest file of each
  boots="$(while IFS= read -r f; do boot_of_file "$f"; done < "$all" \
           | awk '!seen[$0]++' | tail -n "$keepboots")"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    nf="$(grep "/$b-" "$all" | tail -n 1)"
    [ -n "$nf" ] && printf '%s\n' "$nf" >> "$keep"
  done <<EOF
$boots
EOF
  sort -u "$keep" -o "$keep"
  while IFS= read -r f; do
    grep -qxF "$f" "$keep" || rm -f "$f"
  done < "$all"
  rm -f "$all" "$keep"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/prune_test.sh`
Expected: PASS — `4 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/prune_test.sh
git commit -m "feat: history retention with per-boot protection"
```

---

### Task 6: Migration seeding + wire into `cmd_snapshot`

**Files:**
- Modify: `bin/cc-session-restore` (add `seed_history_from_snapshot`, `record_snapshot`; rewire the tail of `cmd_snapshot`)
- Create: `test/record_test.sh`

**Interfaces:**
- Consumes: `newest_history`, `current_boot`, `now_ts`, `append_snapshot`, `prune_history`, `$SNAPSHOT`.
- Produces: `seed_history_from_snapshot` (if history empty and `snapshot.tsv` non-empty, seed one current-boot entry from it), `record_snapshot CANDIDATE` (= seed → append → prune).

- [ ] **Step 1: Write the failing test**

Create `test/record_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/record_test.sh`
Expected: FAIL — `seed_history_from_snapshot`/`record_snapshot` undefined.

- [ ] **Step 3: Add the functions and rewire `cmd_snapshot`**

Add after `prune_history`:

```bash
# One-time migration: if there's no history yet but a legacy snapshot.tsv
# exists, preserve it as the first history entry (tagged with the current boot).
seed_history_from_snapshot() {
  [ -n "$(newest_history)" ] && return 0
  [ -s "$SNAPSHOT" ] || return 0
  local cur ts
  cur="$(current_boot)"; ts="$(now_ts)"
  mkdir -p "$STATE_DIR/history"
  cp "$SNAPSHOT" "$STATE_DIR/history/$cur-$ts.tsv"
}

record_snapshot() { # $1 = candidate tsv (may be empty)
  seed_history_from_snapshot
  append_snapshot "$1"
  prune_history
}
```

Replace the tail of `cmd_snapshot` (currently the block computing `n` and doing the empty-guard `mv`, lines ~70-76) with:

```bash
  local n; n="$(grep -c . "$tmp" 2>/dev/null || true)"; n="${n:-0}"
  record_snapshot "$tmp"
  rm -f "$tmp"
  if [ "$n" -eq 0 ]; then
    echo "snapshot: 0 live sessions; kept existing history"
  else
    echo "snapshot: captured $n live session(s) -> history"
  fi
```

(Leave everything above it — the `SESSIONS_DIR` scan building `$tmp` — unchanged. Remove the old `mv "$tmp" "$SNAPSHOT"` since `record_snapshot`/`append_snapshot` now own `$SNAPSHOT`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/record_test.sh`
Expected: PASS — `4 run, 0 failed`.
Also: `shellcheck bin/cc-session-restore install.sh` → clean.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/record_test.sh
git commit -m "feat: seed legacy snapshot + record via history in cmd_snapshot"
```

---

### Task 7: ID resolution, `--list`, `--show`, and read-only `cmd_restore` paths

**Files:**
- Modify: `bin/cc-session-restore` (add `resolve_id`, `list_history`, `show_snapshot`; begin new `cmd_restore` arg parser handling only `--list`/`--show`; move `require_macos` off these paths)
- Create: `test/cli_readonly_test.sh`

**Interfaces:**
- Consumes: `history_files`, `select_default`, `current_boot`, `$SNAPSHOT`, `die`.
- Produces: `resolve_id ID` (ID = newest-first index of `--list`, OR a unique substring of a filename stem; → path, or nonzero if no unique match), `list_history` (prints table, marks default with `*`), `show_snapshot ID` (prints each session `title` + `cd … && claude --resume …`). `cmd_restore` handles `--list` and `--show <id>` WITHOUT calling `require_macos`.

- [ ] **Step 1: Write the failing test**

Create `test/cli_readonly_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/cli_readonly_test.sh`
Expected: FAIL — old `cmd_restore` doesn't know `--list`/`--show` and calls `require_macos` (dies on Linux).

- [ ] **Step 3: Implement resolve/list/show and the read-only arg paths**

Add after `select_default` (or grouped with selection helpers):

```bash
# Resolve an id (newest-first index from --list, or a unique filename-stem
# substring) to a history file path. Nonzero if no unique match.
resolve_id() { # $1 = id
  local id="$1" total match c
  total="$(history_files | grep -c . )"
  case "$id" in
    ''|*[!0-9]*) : ;;                        # not a pure integer
    *)
      if [ "$id" -ge 1 ] && [ "$id" -le "$total" ]; then
        history_files | sed -n "$((total - id + 1))p"   # newest-first
        return 0
      fi
      ;;
  esac
  match="$(history_files | while IFS= read -r f; do
    case "$(basename "$f")" in *"$id"*) printf '%s\n' "$f" ;; esac
  done)"
  c="$(printf '%s\n' "$match" | grep -c . )"
  if [ "$c" = 1 ]; then printf '%s\n' "$match"; return 0; fi
  return 1
}

# YYYYMMDDTHHMMSS -> "YYYY-MM-DD HH:MM"
_human_ts() {
  sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2}).*/\1-\2-\3 \4:\5/'
}

list_history() {
  local total idx i f base boot ts count cur def human marker star
  cur="$(current_boot)"
  total="$(history_files | grep -c . )"
  if [ "$total" -eq 0 ]; then echo "(no snapshots yet)"; return 0; fi
  def="$(select_default)"
  printf '   %-3s %-16s  %-10s  %-8s  %s\n' "#" "captured" "boot" "count" "id"
  idx=0
  while [ "$idx" -lt "$total" ]; do
    i=$((idx + 1))
    f="$(history_files | sed -n "$((total - idx))p")"   # newest-first
    base="$(basename "$f" .tsv)"; boot="${base%%-*}"; ts="${base#*-}"
    count="$(grep -c . "$f")"
    if [ "$boot" = "$cur" ]; then marker="this-boot"; else marker="prior-boot"; fi
    if [ "$f" = "$def" ]; then star="*"; else star=" "; fi
    human="$(printf '%s' "$ts" | _human_ts)"
    printf ' %s %-3s %-16s  %-10s  %-8s  %s\n' "$star" "$i" "$human" "$marker" "$count" "$base"
    idx=$((idx + 1))
  done
  echo
  echo "* = default target for 'restore'"
}

show_snapshot() { # $1 = id
  local f sid cwd title
  f="$(resolve_id "$1")" || die "no snapshot matching '$1' (see: cc-session-restore restore --list)"
  while IFS=$'\t' read -r sid cwd title; do
    [ -n "$sid" ] || continue
    printf '%s\n   cd %s && claude --resume %s\n' "${title:-$sid}" "$cwd" "$sid"
  done < "$f"
}
```

Replace `cmd_restore` with a version that parses args and handles the read-only modes now (launch modes come in Task 8):

```bash
cmd_restore() {
  local dry=0 yes=0 mode="default" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)  dry=1 ;;
      -y|--yes)   yes=1 ;;
      --latest)   mode="latest" ;;
      --list)     mode="list" ;;
      --show)     mode="show"; shift; id="${1:-}"; [ -n "$id" ] || die "restore --show needs an id" ;;
      --snapshot) mode="snapshot"; shift; id="${1:-}"; [ -n "$id" ] || die "restore --snapshot needs an id" ;;
      *) die "restore: unknown option '$1'" ;;
    esac
    shift
  done

  [ -n "$(newest_history)" ] || [ -s "$SNAPSHOT" ] \
    || die "no snapshots yet (run: cc-session-restore snapshot)"

  case "$mode" in
    list) list_history; return 0 ;;
    show) show_snapshot "$id"; return 0 ;;
  esac

  # launch modes handled in Task 8
  die "restore: launch not wired yet"
}
```

Keep `require_macos` OUT of `cmd_restore`; it moves into `launch_file` (Task 8).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/cli_readonly_test.sh`
Expected: PASS — `8 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/cli_readonly_test.sh
git commit -m "feat: restore --list/--show + id resolution (no macOS needed)"
```

---

### Task 8: Launch refactor + `restore` launch selectors

**Files:**
- Modify: `bin/cc-session-restore` (add `launch_file`; complete `cmd_restore` launch modes)
- Create: `test/cli_launch_test.sh`

**Interfaces:**
- Consumes: `require_macos`, `resolve_id`, `select_default`, `newest_history`, `$SNAPSHOT`, `die`.
- Produces: `launch_file FILE DRY` (DRY=1 prints `cd … && claude --resume …` per session, no macOS; DRY=0 requires macOS+iTerm2 and drives AppleScript). `cmd_restore` completes `--latest`/`--snapshot`/default selection and routes to `launch_file`.

- [ ] **Step 1: Write the failing test**

Create `test/cli_launch_test.sh`:

```bash
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
out="$(run restore --snapshot 2 --dry-run </dev/null)"
assert_contains "$out" "claude --resume s1" "--snapshot 2 = older set"

# dry-run must not require macOS (would have died otherwise on Linux).
assert_eq "0" "$?" "dry-run exits 0 on non-macOS"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/cli_launch_test.sh`
Expected: FAIL — `cmd_restore` currently dies with "launch not wired yet".

- [ ] **Step 3: Add `launch_file` and finish `cmd_restore`**

Add `launch_file` (adapt the existing AppleScript builder, moving `require_macos` and the iTerm2 check here, and taking the file + dry flag as args):

```bash
launch_file() { # $1 = tsv file, $2 = dry (0/1)
  local file="$1" dry="$2" n sid cwd title cmd osa first=1 stem
  stem="$(basename "$file" .tsv)"
  n="$(grep -c . "$file")"
  if [ "$dry" = 1 ]; then
    echo "restore (dry-run): $n session(s) from $stem"
    while IFS=$'\t' read -r sid cwd title; do
      [ -n "$sid" ] || continue
      printf '  %s  (%s)\n     cd %s && claude --resume %s\n' "${title:-$sid}" "$sid" "$cwd" "$sid"
    done < "$file"
    return 0
  fi
  require_macos
  osascript -e 'id of app "iTerm"' >/dev/null 2>&1 \
    || die "iTerm2 not found — this version restores into iTerm2 only."
  osa='tell application "iTerm2"
  activate
  set w to (create window with default profile)
'
  while IFS=$'\t' read -r sid cwd title; do
    [ -n "$sid" ] || continue
    cmd="cd \\\"$cwd\\\" && claude --resume $sid"
    if [ "$first" = 1 ]; then
      osa+="  tell current session of w to write text \"$cmd\"
"
      first=0
    else
      osa+="  tell w to create tab with default profile
  tell current session of w to write text \"$cmd\"
"
    fi
  done < "$file"
  osa+='end tell'
  printf '%s\n' "$osa" | osascript -
  echo "restore: launched $n tab(s) from $stem."
}
```

Replace the `# launch modes handled in Task 8` / `die "restore: launch not wired yet"` block at the end of `cmd_restore` with:

```bash
  local file=""
  case "$mode" in
    latest)
      file="$(newest_history)"; [ -n "$file" ] || file="$SNAPSHOT" ;;
    snapshot)
      file="$(resolve_id "$id")" \
        || die "no snapshot matching '$id' (see: cc-session-restore restore --list)" ;;
    default)
      file="$(select_default)"
      [ -n "$file" ] || file="$SNAPSHOT" ;;
  esac
  [ -n "$file" ] && [ -s "$file" ] || die "nothing to restore"
  launch_file "$file" "$dry"
```

(The interactive picker for `default` mode is added in Task 9; for now `default` resolves via `select_default`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/cli_launch_test.sh`
Expected: PASS — `5 run, 0 failed`.
Also: `shellcheck bin/cc-session-restore install.sh` → clean.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/cli_launch_test.sh
git commit -m "feat: launch_file + restore --latest/--snapshot/default (dry-run)"
```

---

### Task 9: Interactive picker (fzf + numbered-menu fallback)

**Files:**
- Modify: `bin/cc-session-restore` (add `pick_interactive`, `_pick_lines`, `_pick_menu`; wire into `cmd_restore` default mode)
- Create: `test/pick_test.sh`

**Interfaces:**
- Consumes: `history_files`, `select_default`, `resolve_id`, `current_boot`, `self_path`.
- Produces: `pick_interactive` (→ chosen history file path on stdout; nonzero if cancelled). Uses `fzf` when available on a TTY; otherwise `_pick_menu` (prompt + list on **stderr**, reads an index/id from stdin, default = the reboot-aware entry). `cmd_restore` default mode uses the picker only when stdout AND stdin are TTYs and `-y` was not given; else falls back to `select_default`.

- [ ] **Step 1: Write the failing test**

Create `test/pick_test.sh` (tests the fallback menu deterministically; the fzf path is verified manually):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/pick_test.sh`
Expected: FAIL — `_pick_menu` undefined.

- [ ] **Step 3: Add the picker functions and wire into `cmd_restore`**

Add near `list_history`:

```bash
# Lines for fzf: "<id>\t<display>"; --with-nth hides the id column.
_pick_lines() {
  local total idx f base boot ts count cur human marker
  cur="$(current_boot)"
  total="$(history_files | grep -c . )"
  idx=0
  while [ "$idx" -lt "$total" ]; do
    f="$(history_files | sed -n "$((total - idx))p")"   # newest-first
    base="$(basename "$f" .tsv)"; boot="${base%%-*}"; ts="${base#*-}"
    count="$(grep -c . "$f")"
    if [ "$boot" = "$cur" ]; then marker="this-boot "; else marker="prior-boot"; fi
    human="$(printf '%s' "$ts" | _human_ts)"
    printf '%s\t%s  %s  %s sessions\n' "$base" "$human" "$marker" "$count"
    idx=$((idx + 1))
  done
}

_pick_menu() {
  local total ans idx f defidx=1
  total="$(history_files | grep -c . )"
  [ "$total" -gt 0 ] || return 1
  list_history >&2
  local def; def="$(select_default)"
  idx=0
  while [ "$idx" -lt "$total" ]; do
    f="$(history_files | sed -n "$((total - idx))p")"
    [ "$f" = "$def" ] && defidx=$((idx + 1))
    idx=$((idx + 1))
  done
  printf 'Restore which? [%s]: ' "$defidx" >&2
  IFS= read -r ans || true
  [ -n "$ans" ] || ans="$defidx"
  resolve_id "$ans" || return 1
}

_pick_fzf() {
  local self line id
  self="$(self_path)"
  line="$(_pick_lines | fzf --ansi --delimiter=$'\t' --with-nth=2.. \
          --height=40% --reverse --no-multi \
          --preview "$self restore --show {1}" --preview-window=right,50%)" || return 1
  [ -n "$line" ] || return 1
  id="${line%%$'\t'*}"
  resolve_id "$id"
}

pick_interactive() {
  [ -n "$(history_files | grep -c . )" ] || { select_default; return 0; }
  if command -v fzf >/dev/null 2>&1; then
    _pick_fzf
  else
    _pick_menu
  fi
}
```

Update the `default)` arm of `cmd_restore` (from Task 8) to prefer the picker on an interactive terminal:

```bash
    default)
      if [ "$yes" = 0 ] && [ -t 0 ] && [ -t 1 ]; then
        file="$(pick_interactive)" || return 0     # cancelled = no launch
      else
        file="$(select_default)"
      fi
      [ -n "$file" ] || file="$SNAPSHOT" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/pick_test.sh`
Expected: PASS — `2 run, 0 failed`.

Manual check on macOS (not in CI): with `fzf` installed, `cc-session-restore restore` opens the picker with a preview pane; Enter launches, Esc cancels. Without `fzf`, a numbered menu appears.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore test/pick_test.sh
git commit -m "feat: interactive picker (fzf + numbered-menu fallback)"
```

---

### Task 10: `status`, usage, version bump, README, CI

**Files:**
- Modify: `bin/cc-session-restore` (`cmd_status`, `usage`, `VERSION`)
- Modify: `VERSION`
- Modify: `README.md`
- Modify: `.github/workflows/ci.yml`
- Create: `test/status_test.sh`

**Interfaces:**
- Consumes: `history_files`, `select_default`, `grep`.
- Produces: `cmd_status` prints a `history:` count line and a `restore target:` line; CI gains a `tests` job running `bash test/run.sh`.

- [ ] **Step 1: Write the failing test**

Create `test/status_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/status_test.sh`
Expected: FAIL — no `history:`/`restore target:` lines yet.

- [ ] **Step 3: Update `cmd_status`, `usage`, versions, README, CI**

In `cmd_status`, after the `last snapshot:` block and before the launch-agent check, add:

```bash
  local hc; hc="$(history_files | grep -c . )"
  printf 'history:         %s snapshot(s)\n' "$hc"
  local def; def="$(select_default)"
  if [ -n "$def" ]; then
    printf 'restore target:  %s (%s session(s))\n' "$(basename "$def" .tsv)" "$(grep -c . "$def")"
  fi
```

Bump `VERSION="0.1.0"` → `VERSION="0.2.0"` in the script, and the `VERSION` file `0.1.0` → `0.2.0`.

Replace the `restore` line in `usage()` and add the new options:

```bash
  restore [opts]        Reopen sessions. With no opts: interactive picker (or the
                        reboot-aware default when non-interactive). Options:
                          --list             list snapshot history (no launch)
                          --show <id>        print the sessions in one snapshot
                          --snapshot <id>    restore a specific snapshot
                          --latest           restore the newest snapshot
                          -y, --yes          skip the picker; use the default
                          --dry-run          show what would reopen
```

In `README.md`: under "Usage" document `--list`/`--show`/`--snapshot`/`--latest`; add a "History & reboot-aware restore" subsection explaining that `restore` defaults to the set open before the last reboot; note `fzf` as an optional "nicer picker" dependency; add `CCSR_HISTORY_LIMIT` and `CCSR_KEEP_BOOTS` to the Configuration table.

In `.github/workflows/ci.yml`, add a second job:

```yaml
  tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: bash test/run.sh
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/status_test.sh` → `4 run, 0 failed`.
Run the whole suite: `bash test/run.sh` → every file reports `0 failed`, exit 0.
Run: `shellcheck bin/cc-session-restore install.sh` → clean.

- [ ] **Step 5: Commit**

```bash
git add bin/cc-session-restore VERSION README.md .github/workflows/ci.yml test/status_test.sh
git commit -m "feat: status history/target lines, docs, v0.2.0, CI tests job"
```

---

## Self-Review

**1. Spec coverage:**
- History storage (boot-tagged files) → Tasks 2, 4.
- Append only on change; empty never clobbers → Task 4.
- Reboot-aware default selection → Task 3, wired in Tasks 8–9.
- `--list`/`--show`/`--snapshot`/`--latest`/`--dry-run`/`-y` → Tasks 7, 8, 9.
- fzf picker + fallback → Task 9.
- Retention (newest N + per-boot K) → Task 5.
- Migration/back-compat seeding → Task 6.
- `require_macos` off read-only paths → Tasks 7, 8.
- `status` additions, version, README, CI → Task 10.
- Bash 3.2 constraint honored (no `mapfile`/`declare -A`) → Task 5 uses temp files.
- Testing = shellcheck + Bash suite on Linux CI → all tasks + Task 10 CI job.

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; "launch not wired yet" in Task 7 is an explicit intermediate `die` replaced in Task 8 (not a placeholder left in the final product).

**3. Type/name consistency:** `select_default`, `history_files`, `newest_history`, `boot_of_file`, `append_snapshot`, `prune_history`, `seed_history_from_snapshot`, `record_snapshot`, `resolve_id`, `list_history`, `show_snapshot`, `launch_file`, `pick_interactive`, `_pick_lines`, `_pick_menu`, `_pick_fzf`, `_human_ts`, `current_boot`, `now_ts`, `_parse_boottime` — names are used identically across tasks. `$STATE_DIR`, `$SNAPSHOT`, `$CCSR_BOOT_OVERRIDE`, `$CCSR_NOW_OVERRIDE`, `$CCSR_HISTORY_LIMIT`, `$CCSR_KEEP_BOOTS` consistent. History filename `<boot>-<ts>.tsv` consistent throughout.

**Note for the implementer:** Test files `source "$BIN"`, which runs the script's top-level `export PATH=/usr/bin:/bin:/usr/sbin:/sbin` and `export LC_ALL=C`. That's fine on Ubuntu CI (coreutils live in `/usr/bin`,`/bin`). The source-guard (Task 1) is what keeps `main` from running on `source`.
