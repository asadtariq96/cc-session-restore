#!/usr/bin/env bash
# cc-session-restore installer.
#
# Remote use:
#   curl -fsSL https://raw.githubusercontent.com/asadtariq96/cc-session-restore/v0.1.0/install.sh | bash
# Local use (from a checkout):
#   ./install.sh
set -euo pipefail

# ---- edit these for your fork ----------------------------------------------
REPO="${CCSR_REPO:-asadtariq96/cc-session-restore}"
TAG="${CCSR_TAG:-v0.1.0}"
# ----------------------------------------------------------------------------

BIN_DIR="${CCSR_BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/cc-session-restore"
RAW="https://raw.githubusercontent.com/$REPO/$TAG/bin/cc-session-restore"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { echo "cc-session-restore is macOS-only." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }

mkdir -p "$BIN_DIR"

# Prefer a local checkout (this file sitting next to bin/); else download the pinned tag.
# BASH_SOURCE is unset when piped via `curl | bash`, so guard it under `set -u`.
src="${BASH_SOURCE[0]:-}"
local_bin=""
[ -n "$src" ] && local_bin="$(cd "$(dirname "$src")" && pwd -P)/bin/cc-session-restore"

if [ -n "$local_bin" ] && [ -f "$local_bin" ]; then
  install -m 0755 "$local_bin" "$DEST"
  bold "Installed from local checkout -> $DEST"
else
  bold "Downloading cc-session-restore ($TAG)..."
  curl -fsSL "$RAW" -o "$DEST"
  chmod 0755 "$DEST"
  bold "Installed -> $DEST"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) bold "NOTE: $BIN_DIR is not on your PATH. Add to your shell rc:"
     # shellcheck disable=SC2016  # the literal $PATH in the printed hint is intentional
     printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac

# Install + load the auto-snapshot agent, then take a first snapshot.
"$DEST" agent install
"$DEST" snapshot || true

cat <<EOF

$(bold "Done.")
  • One-time: the first 'cc-session-restore restore' asks macOS for permission to
    control iTerm2 — click OK.
  • Snapshots now run automatically every 60s.
  • After a reboot:   cc-session-restore restore
  • Preview anytime:  cc-session-restore restore --dry-run
  • Uninstall:        cc-session-restore uninstall
EOF
