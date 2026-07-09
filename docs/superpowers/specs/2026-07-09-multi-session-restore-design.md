# Multi-session restore (history + reboot-aware selection)

- **Date:** 2026-07-09
- **Status:** Draft — awaiting user approval
- **Component:** `bin/cc-session-restore`

## Problem

`snapshot` writes a single file, `snapshot.tsv`, replacing it on every run. The only
guard (bin/cc-session-restore:72–74) refuses to overwrite a good snapshot with a
**zero-session** one — it does nothing about a *smaller* one.

Failure scenario: 5 sessions are open; the laptop reboots; the user opens **one** fresh
`claude` instead of running `restore`. Within ≤60s the LaunchAgent runs `snapshot`, sees
1 live session (count = 1, not 0), and clobbers the 5-session snapshot. The conversations
are still journaled on disk, but the record of *which sessions were open together before
the reboot* is gone. There is no way to get that set back.

Root cause: a **lossy, single-slot** snapshot with no history. The fix lives entirely in
how snapshots are persisted and selected — not in how Claude's files are read.

## Goals

- Never lose the "set of sessions open before a reboot" just because a newer, smaller
  snapshot was taken.
- Let the user restore a *previous* snapshot, not only the latest.
- Make the common case (reboot → recover the pre-reboot set) require zero manual picking.
- Keep the tool a **single Bash script** with **zero required dependencies** and the same
  `curl | bash` distribution. Any picker UI is an *optional* enhancement that degrades
  gracefully.

## Non-goals

- No rewrite into another language/runtime (see "Picker" decision below).
- No change to how sessions are discovered from `~/.claude/sessions/*.json` (that logic,
  including the live-PID and recycled-PID checks, is unchanged).
- No multi-window / multi-terminal support changes (still one iTerm2 window).
- No restoring *multiple* snapshots in one invocation (a snapshot already is a set).

## Decisions requiring user confirmation

1. **`restore` default behavior.** Recommendation: `restore` opens the interactive picker
   (TTY only), with the reboot-aware entry pre-selected at the top; Enter confirms. A
   non-interactive stdin, or `-y/--yes`, runs the reboot-aware default directly without a
   prompt. Alternative: keep `restore` auto-launching (current muscle memory) and gate the
   picker behind `restore --pick`.
2. **Selection default = prior-boot set** (not newest-overall). Correct for a
   reboot-recovery tool, but it means bare `restore` won't reopen *current-boot* sessions
   unless you pass `--latest`.
3. **Picker tech = fzf with a pure-Bash numbered-menu fallback** (not Rust/ratatui, which
   is what `claude-history` uses and which would require rewriting the project). fzf is an
   optional dependency; absence triggers the numbered menu.
4. **Retention policy** (see below): keep newest 50 distinct snapshots, but always protect
   the newest entry of each of the last 10 boots. Configurable via env.

## Design

### Data layout

Replace the single slot with an append-only history directory. `snapshot.tsv` remains as
the "latest non-empty capture" pointer for backward-compat and `status`.

```
$STATE_DIR/                                  # ~/.local/state/cc-session-restore
  snapshot.tsv                               # unchanged role: latest non-empty capture
  history/
    1783594214-20260709T135900.tsv           # <boot_epoch_sec>-<UTC_timestamp>.tsv
    1783594214-20260709T140300.tsv
    1783620000-20260709T210500.tsv           # different boot prefix ⇒ a reboot happened
```

- **Body** of each history file is the exact same TSV `restore` already parses
  (`sid \t cwd \t title`). **No parser changes, no header lines.**
- **Filename** = `<boot>-<ts>`. `boot` is the kernel boot time in epoch seconds (stable
  within a boot, changes on reboot); `ts` is UTC capture time. Both fixed-width and
  zero-padded enough that lexicographic `sort` == chronological sort.

### Boot-time tagging

```sh
sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+).*/\1/'
```

Verified on macOS 15: raw is `{ sec = 1783594214, usec = 586840 } Thu Jul  9 ...`; the
sed yields `1783594214`. `/usr/sbin` is already on the script's restricted `PATH`. This is
the one new primitive the whole reboot-aware behavior rests on.

### `cmd_snapshot` changes

Build the live-session list exactly as today (unchanged discovery + PID checks) into a
temp file, then:

1. Compute current `boot`.
2. If the list is **non-empty**:
   - Compare its body against the body of the newest existing `history/*` file (`cmp -s`).
   - If different (or history is empty) → append `history/<boot>-<ts>.tsv`.
     (Dedup prevents ~1440 identical files/day; only *changes* create entries.)
   - Refresh `snapshot.tsv` from this capture.
3. If the list is **empty** → do nothing to `history/`, keep the existing `snapshot.tsv`
   (same spirit as today's zero-guard; this is what preserves the pre-reboot set when the
   machine comes back up with no `claude` running).
4. Prune history (retention, below).

### Selection rule (the reboot-aware default)

Given the sorted history, the default target is:

> the **newest** snapshot whose `boot` prefix **≠ the current boot**; if none exists, the
> **newest overall**.

Why it works:

| Situation | History (newest last) | Default picks |
|---|---|---|
| Reboot, opened 1 fresh session | `B1(5) … B2(1)` | `B1(5)` — the pre-reboot set ✅ |
| Reboot, opened nothing | `B1(5)` (B2 empty, not appended) | `B1(5)` ✅ |
| No reboot since first snapshot | `B1(…) …` only | newest overall (today's behavior) |
| Second reboot after working | `… B2(n) … B3(m)` | newest `B2` entry (the set before this reboot) |

The chosen new session IDs after a reboot are always fresh UUIDs, so restoring the old set
never collides with the one the user already opened.

### CLI surface

| Command | Behavior |
|---|---|
| `restore` | Interactive picker (TTY), reboot-aware entry pre-selected; Enter launches. Non-TTY or `-y` → launch reboot-aware default directly. |
| `restore -y`, `--yes` | Skip picker; launch reboot-aware default. |
| `restore --latest` | Launch newest-overall snapshot (old behavior). Skips picker. |
| `restore --snapshot <id>` | Launch a specific snapshot. `<id>` = the timestamp token *or* the index shown by `--list`. Skips picker. |
| `restore --list` | Print history table (index, local time, boot marker, session count). No launch. |
| `restore --show <id>` | Print the sessions inside one snapshot (title + cwd). Also used as the picker's preview backend. |
| `restore --dry-run` | Compose with any selector; show `cd … && claude --resume …` lines instead of launching. |
| `status` | Additionally: history entry count, and which snapshot `restore` would pick (id, count, reason). |

All existing commands (`snapshot`, `agent …`, `uninstall`, `--version`, `--help`) are
unchanged in name and meaning.

### Picker (fzf + fallback)

- Use fzf only when `command -v fzf` succeeds **and** stdout is a TTY; otherwise the
  numbered-menu fallback.
- fzf invocation feeds lines `"<id>\t<label>"`, hides the id column with
  `--delimiter '\t' --with-nth 2..`, and sets the preview to
  `cc-session-restore restore --show {1}` so the right pane lists that snapshot's sessions
  (title + cwd) — close to claude-history's list+preview split.
- Selection returns the `id`; restore then runs that snapshot through the same launch path.
- Fallback (no fzf / no TTY): print the numbered `--list` table, `read` an index (default =
  the reboot-aware entry), launch it.

The installer never installs fzf and never requires it; README notes it as an optional
"nicer picker" dependency.

### Retention / eviction

On each snapshot, after appending, prune so the pre-reboot set can never be evicted by
churn within a single long uptime:

- Keep the newest `CCSR_HISTORY_LIMIT` (default **50**) entries overall, **and**
- always keep the newest entry of each of the last `CCSR_KEEP_BOOTS` (default **10**)
  distinct boots, even if that pushes total > 50.

Delete only entries excluded by *both* rules.

### Backward compatibility / migration

- On first run after upgrade, if `history/` is empty and `snapshot.tsv` is non-empty, seed
  one history entry from `snapshot.tsv` (tagged with the current boot and the file's mtime
  timestamp) so a pre-upgrade open set isn't lost.
- Until a second *distinct* capture exists, `restore` resolves to the same single set as
  today — no behavior change for existing users on day one.

### Edge cases

- **Empty captures never append** and never refresh `snapshot.tsv` → pre-reboot set is
  safe while the machine has no `claude` running.
- **Dedup** via `cmp -s` against the newest entry only (cheap, avoids churn).
- **Recycled PIDs** — unchanged existing `ps -o comm=` check.
- **Corrupt/partial history file** — a row with an empty first field is skipped by the
  existing `[ -n "$sid" ] || continue` guard in the launch loop; `--show`/preview tolerate
  the same.
- **`--snapshot` with a bad id** → clear error listing valid ids, non-zero exit.
- **fzf cancelled (Esc)** → no launch, exit 0.

## Testing

- `shellcheck bin/cc-session-restore install.sh` stays clean (matches existing CI).
- Manual/functional scenarios to verify (documented in the PR):
  1. Fresh install → snapshot → history has 1 entry; `restore --dry-run` matches it.
  2. Simulate reboot by writing history files with two different boot prefixes; assert the
     default selection picks the newest prior-boot entry.
  3. Reboot + one new session (the core bug): assert default picks the 5-session prior-boot
     set, not the 1-session current-boot one.
  4. Churn > 50 distinct snapshots in one boot: assert the prior-boot entry survives.
  5. `restore --snapshot <id>` / `--latest` / `--list` / `--show` behave per table.
  6. fzf-present vs fzf-absent both select correctly (force fallback with `PATH`/env).
- Optional: a small pure-Bash test harness driving the selection + retention functions with
  synthetic `history/` fixtures (no macOS/iTerm2 needed), runnable in CI on Linux.

## Rollout

- Bump `VERSION` / in-script `VERSION` (0.1.0 → 0.2.0).
- README: document history, `--list`/`--snapshot`/`--show`/`--latest`, the reboot-aware
  default, optional fzf, and the new env vars (`CCSR_HISTORY_LIMIT`, `CCSR_KEEP_BOOTS`).
- No installer changes required beyond messaging (fzf stays optional).

## Open questions

- Confirm the four decisions above (esp. #1 picker-by-default vs auto-launch, and #2
  prior-boot default).
- Retention numbers (50 / 10) acceptable, or prefer a simpler "last N" with no per-boot
  protection?
