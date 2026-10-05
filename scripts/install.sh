#!/usr/bin/env bash
# Builds, installs the binary at a stable path and loads the LaunchAgent.
#   ./scripts/install.sh [--swiftc]
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=local.thumbd
DEST="$HOME/.local/bin/thumbd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/thumbd.log"
DOMAIN="gui/$(id -u)"

BIN="$(./scripts/build.sh "$@" | tail -n 1)"

mkdir -p "$(dirname "$DEST")" "$(dirname "$PLIST")" "$(dirname "$LOG")"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the job is fully gone; bootstrapping too early fails with
# "5: Input/output error". Wait (up to ~10 s) until launchd no longer knows the label.
for _ in $(seq 50); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
# rm + cp (new inode): overwriting a signed binary in place can get it killed by the kernel,
# which keeps using the cached signature of the previous file.
rm -f "$DEST"
cp "$BIN" "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST</string>
    <string>run</string>
  </array>
  <!-- Start at login -->
  <key>RunAtLoad</key>
  <true/>
  <!-- Restart if it exits with an error or crashes; not on a clean exit (SIGTERM → exit 0) -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <!-- Without this launchd may apply "background" throttling and add latency -->
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $DEST and loaded $LABEL."
echo "Log:     tail -f $LOG"
echo "Status:  launchctl print $DOMAIN/$LABEL | head -20"
