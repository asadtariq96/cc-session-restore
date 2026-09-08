# cc-session-restore

[![CI](https://github.com/asadtariq96/cc-session-restore/actions/workflows/ci.yml/badge.svg)](https://github.com/asadtariq96/cc-session-restore/actions/workflows/ci.yml)

Reopen all your open Claude Code terminal sessions after a macOS reboot, each in the
right folder and resumed to the exact conversation.

A restart kills the `claude` processes but not the conversations: Claude journals every
session to disk. `cc-session-restore` records which sessions are open (automatically, every
60s) and reopens them after you reboot, in one iTerm2 window, with each tab running
`claude --resume <id>` — carrying over the flags that session was started with, so a tab
launched as `claude --dangerously-skip-permissions --model sonnet` comes back the same way
instead of asking for permissions all over again.

It works even when several sessions share one working directory, where `claude --continue`
can't tell them apart, because it resumes by exact session ID.

## Requirements

- macOS (uses `launchd` and AppleScript)
- iTerm2 (restore opens tabs in iTerm2)
- Claude Code CLI, which writes the per-session files this tool reads from
  `~/.claude/sessions/<PID>.json`

> Note: that `sessions/` file is an internal Claude Code detail, not a public API. This tool
> is tested against Claude Code 2.1.x, and a future Claude release could change it. If
> `status` shows the sessions dir as `MISSING`, your Claude version may be incompatible.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/asadtariq96/cc-session-restore/v0.1.0/install.sh | bash
```

Prefer to read before you run (a good habit for any `curl | bash`):

```sh
git clone https://github.com/asadtariq96/cc-session-restore
cd cc-session-restore
less install.sh   # inspect it
./install.sh
```

The installer drops a single `cc-session-restore` executable in `~/.local/bin`, then installs
and loads a LaunchAgent that snapshots open sessions every 60s.

## Usage

```sh
cc-session-restore status              # config, last snapshot, agent state
cc-session-restore snapshot            # capture open sessions now (also runs every 60s)
cc-session-restore restore --dry-run   # show what would reopen, without launching
cc-session-restore restore             # reopen everything after a reboot
cc-session-restore restore --force     # also reopen sessions that are still running
```

`restore` skips any session that is still open, so running it twice does not stack a second
tab on top of a working one, and running it after a partial reboot only fills the gaps.
`--dry-run` prints the exact command each tab would get, plus the flags it filtered out —
worth a look the first time.

Typical flow: do nothing special before restarting, since the agent keeps a fresh snapshot.
After logging back in, run `cc-session-restore restore`.

### One-time permission

The first `restore` triggers a macOS prompt ("... wants to control iTerm2"). Click OK. You
can change this later under System Settings > Privacy & Security > Automation.

## How it works

- `~/.claude/sessions/<PID>.json` is Claude Code's own live map of running sessions
  (`pid`, `sessionId`, `cwd`, `name`, `status`). `snapshot` reads it and keeps only entries
  whose PID is still a live `claude` process, writing them to
  `${XDG_STATE_HOME:-~/.local/state}/cc-session-restore/snapshot.tsv`.
- Launch flags are not in that file, nor anywhere else on disk — argv exists only in the
  running process. `snapshot` reads it with `ps` while the PID is alive and stores it in the
  snapshot's fifth column.
- `restore` builds an AppleScript that opens one iTerm2 window and one tab per row, each
  running `cd <cwd> && command claude <flags> --resume <id>`. Flags that would fight with
  `--resume` are dropped first: `--resume`, `--continue`, `--session-id`, `--fork-session`,
  `--from-pr`, `--cloud`, `--worktree`, `--print`, `--bg` and a trailing prompt argument.
  A session name you set yourself with `-n` is restored from the session JSON rather than
  from argv, so a name with spaces survives.
- Sessions that are not terminal tabs are left alone: hooks and SDK callers run
  `claude --print ...` and register as `entrypoint: sdk-cli`. So are sessions Claude Code
  has not journalled yet — `--resume` has nothing to find for those.

Closed tabs drop out of the next 60s snapshot, so there's nothing to prune by hand. An
unexpected reboot loses at most ~60s of "which tabs were open", and never loses a
conversation.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Where Claude stores its config and sessions |
| `XDG_STATE_HOME` | `~/.local/state` | Where the snapshot is written |
| `CCSR_BIN_DIR` | `~/.local/bin` | Install location (installer) |

## Uninstall

```sh
cc-session-restore uninstall            # removes the agent and state, prints the rm for the binary
```

## Limitations

- iTerm2 only for now. Terminal.app, tmux, and others aren't supported yet; PRs welcome.
- Restores all snapshotted sessions into a single window.
- Command-line flags come back; environment variables do not. A session started by a wrapper
  that exports something (its own `CLAUDE_CONFIG_DIR`, a different endpoint) is restored
  without that environment.
- `ps` joins argv with spaces and quotes nothing, so a flag value containing a space (say
  `--append-system-prompt 'be brief'`) comes back split. The common case, `-n`, is handled
  separately; the rest is a known gap.
- The permission mode a session ends up in (`/permissions`, shift-tab) is not restored —
  only the mode it was launched with, if that was a command-line flag.

## License

MIT. See [LICENSE](LICENSE).
