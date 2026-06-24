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
cc-session-restore status              # config, last snapshot, agent state
cc-session-restore snapshot            # capture open sessions now (also runs every 60s)
cc-session-restore restore --dry-run   # show what would reopen, without launching
cc-session-restore restore             # reopen everything after a reboot
```

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
- `restore` builds an AppleScript that opens one iTerm2 window and one tab per row,
  each running `cd <cwd> && claude --resume <id>`.

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

## License

MIT. See [LICENSE](LICENSE).
