#!/usr/bin/env bash
#
# install.sh — Install the simple-media-transcoder (SMT) macOS LaunchAgent.
#
# This generates a per-user LaunchAgent at:
#   ~/Library/LaunchAgents/ch.marvinvr.smt.plist
# so the Bun-based server auto-starts at login and is restarted if it crashes
# (KeepAlive = true).
#
# Run it from anywhere:  ./install/install.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths dynamically from this script's own location.
# REPO_DIR is the parent of the directory containing this script (install/).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

LABEL="ch.marvinvr.smt"
SERVER_TS="$REPO_DIR/server/server.ts"
DATA_DIR="$HOME/Library/Application Support/simple-media-transcoder"
LOG_FILE="$DATA_DIR/run.log"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"

# PATH made available to the service (and its children, e.g. transcode.sh).
# /opt/homebrew/bin is required so ffmpeg/ffprobe are found on Apple Silicon.
SERVICE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Small helper for fatal errors.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Locate the Bun binary. Prefer the one on PATH, fall back to ~/.bun/bin/bun.
# ---------------------------------------------------------------------------
BUN_BIN="$(command -v bun 2>/dev/null || true)"
if [[ -z "$BUN_BIN" ]]; then
  if [[ -x "$HOME/.bun/bin/bun" ]]; then
    BUN_BIN="$HOME/.bun/bin/bun"
  else
    die "Could not find the 'bun' binary. Install Bun (https://bun.sh) or ensure ~/.bun/bin/bun exists, then re-run."
  fi
fi
echo "Using bun:    $BUN_BIN"

# ---------------------------------------------------------------------------
# Sanity checks.
# ---------------------------------------------------------------------------
echo "Repo dir:     $REPO_DIR"
[[ -f "$SERVER_TS" ]] || die "Server entry point not found at: $SERVER_TS"
echo "Server entry: $SERVER_TS"

# ---------------------------------------------------------------------------
# Ensure required directories exist.
# The server also creates the data dir at runtime, but we create it here so the
# log file's parent exists the moment launchd starts the process.
# ---------------------------------------------------------------------------
mkdir -p "$DATA_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

# ---------------------------------------------------------------------------
# Generate the LaunchAgent plist.
# Note: directory paths can contain spaces ("Application Support"), which is
# fine inside the <string> elements of a plist.
# ---------------------------------------------------------------------------
echo "Writing plist: $PLIST_PATH"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BUN_BIN}</string>
        <string>run</string>
        <string>${SERVER_TS}</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${SERVICE_PATH}</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>

    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# (Re)load the LaunchAgent idempotently using the modern launchctl API.
# If a previous instance is loaded, boot it out first, then bootstrap fresh.
# ---------------------------------------------------------------------------
DOMAIN="gui/$(id -u)"

echo "Reloading LaunchAgent in domain $DOMAIN ..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_PATH" \
  || die "launchctl bootstrap failed for $PLIST_PATH"
launchctl enable "$DOMAIN/$LABEL" || true
launchctl kickstart -k "$DOMAIN/$LABEL" \
  || die "launchctl kickstart failed for $DOMAIN/$LABEL"

# ---------------------------------------------------------------------------
# Friendly next steps.
# ---------------------------------------------------------------------------
HOST_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo localhost)"

cat <<INFO

✅ simple-media-transcoder is installed and running.

   Service label : $LABEL
   Plist         : $PLIST_PATH
   Working dir   : $REPO_DIR
   Log file      : $LOG_FILE

   It will start automatically at login and restart automatically if it crashes.

🌐 Web UI:
   Local : http://localhost:8787
   LAN   : http://${HOST_NAME}.local:8787   (or use this Mac's LAN IP address)

🛠  Useful commands:
   Tail logs    : tail -f "$LOG_FILE"
   Restart      : launchctl kickstart -k $DOMAIN/$LABEL
   Stop/remove  : ./install/uninstall.sh

INFO
