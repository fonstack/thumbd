#!/usr/bin/env bash
# Unloads the LaunchAgent (thumbd undoes the diversion on SIGTERM) and removes what was installed.
set -euo pipefail

LABEL=local.thumbd
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/thumbd"
echo "Uninstalled. Config and log are kept in ~/.config/thumbd and ~/Library/Logs/thumbd.log."
