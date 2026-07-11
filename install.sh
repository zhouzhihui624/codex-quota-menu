#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex 实时额度.app"
SOURCE_APP="$ROOT/build/$APP_NAME"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/local.codex.quota-menu.plist"
LABEL="local.codex.quota-menu"
UID_VALUE="$(id -u)"

"$ROOT/build.sh" >/dev/null

launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
pkill -x CodexQuotaMenu 2>/dev/null || true

mkdir -p "$TARGET_DIR" "$AGENT_DIR" "$HOME/Library/Logs"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
cp "$ROOT/LaunchAgent.plist" "$AGENT"

plutil -lint "$AGENT" >/dev/null
launchctl bootstrap "gui/$UID_VALUE" "$AGENT"

echo "Installed: $TARGET_APP"

