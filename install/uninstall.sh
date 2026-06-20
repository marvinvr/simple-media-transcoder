#!/usr/bin/env bash
#
# uninstall.sh — Stop and remove the simple-media-transcoder (SMT) LaunchAgent.
#
# This stops the running service and deletes the LaunchAgent plist so it no
# longer auto-starts at login. It does NOT touch your data directory or the
# database — your transcoding settings/history are preserved.
#
# Run it from anywhere:  ./install/uninstall.sh
#
set -euo pipefail

LABEL="ch.marvinvr.smt"
DATA_DIR="$HOME/Library/Application Support/simple-media-transcoder"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# ---------------------------------------------------------------------------
# Stop / unload the service. Ignore errors (e.g. it may not be loaded).
# ---------------------------------------------------------------------------
echo "Stopping LaunchAgent $LABEL in domain $DOMAIN ..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Remove the plist so it no longer loads at login.
# ---------------------------------------------------------------------------
if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
  echo "Removed plist: $PLIST_PATH"
else
  echo "No plist found at: $PLIST_PATH (nothing to remove)"
fi

# ---------------------------------------------------------------------------
# Inform the user — but do NOT delete user data automatically.
# ---------------------------------------------------------------------------
cat <<INFO

✅ simple-media-transcoder service stopped and removed.
   It will no longer start at login.

ℹ️  Your data was NOT deleted. The data directory and database remain at:
       $DATA_DIR

   If you want to fully purge ALL data (settings, database, logs, admin
   password), run this manually — this is irreversible:

       rm -rf "$DATA_DIR"

INFO
