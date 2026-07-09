# cc-session-restore

[![CI](https://github.com/asadtariq96/cc-session-restore/actions/workflows/ci.yml/badge.svg)](https://github.com/asadtariq96/cc-session-restore/actions/workflows/ci.yml)

Reopen all your open Claude Code terminal sessions after a macOS reboot, each in the
right folder and resumed to the exact conversation.

A restart kills the `claude` processes but not the conversations: Claude journals every
session to disk. `cc-session-restore` records which sessions are open (automatically, every
60s) and reopens them after you reboot, in one iTerm2 window, with each tab running
`claude --resume <id>`.

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
cc-session-restore status              # config, last snapshot, history, agent state
cc-session-restore snapshot            # capture open sessions now (also runs every 60s)
cc-session-restore restore --dry-run   # show what would reopen, without launching
cc-session-restore restore             # reopen everything after a reboot
```

Typical flow: do nothing special before restarting, since the agent keeps a fresh snapshot.
After logging back in, run `cc-session-restore restore`.

`restore` also takes options for working with snapshot history instead of just the latest one:

```sh
cc-session-restore restore --list             # list snapshot history, newest first
cc-session-restore restore --show <id>        # print the sessions in one snapshot, without launching
cc-session-restore restore --snapshot <id>    # restore a specific snapshot (id = #index or filename substring)
cc-session-restore restore --latest           # restore the newest snapshot, ignoring reboot-aware defaults
cc-session-restore restore -y                 # skip the picker; use the default target
```

### History & reboot-aware restore

Every snapshot capture is appended to a small history (deduplicated, pruned automatically) under
`$XDG_STATE_HOME/cc-session-restore/history/`, tagged with the boot it was captured in. When you
run `restore` with no options, it defaults to the newest snapshot captured *before* your last
reboot — i.e. the set of sessions that were open when you shut down — rather than whatever the
auto-snapshot agent captured moments after boot (which is typically empty or nearly so).

If you're at an interactive terminal, `restore` shows a picker instead of launching the default
outright: [`fzf`](https://github.com/junegunn/fzf) gives a nicer fuzzy-search picker with a live
preview if it's installed, otherwise a numbered-menu fallback is used. Neither the tool nor the
installer requires `fzf` — it's entirely optional.

### One-time permission

The first `restore` triggers a macOS prompt ("... wants to control iTerm2"). Click OK. You
can change this later under System Settings > Privacy & Security > Automation.

## How it works

- `~/.claude/sessions/<PID>.json` is Claude Code's own live map of running sessions
  (`pid`, `sessionId`, `cwd`, `name`, `status`). `snapshot` reads it and keeps only entries
  whose PID is still a live `claude` process, writing them to
  `${XDG_STATE_HOME:-~/.local/state}/cc-session-restore/snapshot.tsv`.
- `restore` builds an AppleScript that opens one iTerm2 window and one tab per row,
  each running `cd <cwd> && claude --resume <id>`.

Closed tabs drop out of the next 60s snapshot, so there's nothing to prune by hand. An
unexpected reboot loses at most ~60s of "which tabs were open", and never loses a
conversation.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Where Claude stores its config and sessions |
| `XDG_STATE_HOME` | `~/.local/state` | Where the snapshot and history are written |
| `CCSR_BIN_DIR` | `~/.local/bin` | Install location (installer) |
| `CCSR_HISTORY_LIMIT` | `50` | Max snapshot history entries to keep overall |
| `CCSR_KEEP_BOOTS` | `10` | Always keep the newest snapshot from each of this many recent boots, even past the limit above |

## Uninstall

```sh
cc-session-restore uninstall            # removes the agent and state, prints the rm for the binary
```

## Limitations

- iTerm2 only for now. Terminal.app, tmux, and others aren't supported yet; PRs welcome.
- Restores all snapshotted sessions into a single window.

## License

MIT. See [LICENSE](LICENSE).
