#!/bin/zsh
set -euo pipefail

LABEL="local.codex.quota-menu"
UID_VALUE="$(id -u)"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
pkill -x CodexQuotaMenu 2>/dev/null || true
rm -rf "$HOME/Applications/Codex 实时额度.app"
rm -f "$AGENT" "$HOME/Library/Logs/CodexQuotaMenu.log"

echo "Codex 实时额度已卸载"

