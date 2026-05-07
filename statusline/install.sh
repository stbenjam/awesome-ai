#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

cp "$SCRIPT_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"

cp "$SCRIPT_DIR/slogans.txt" "$CLAUDE_DIR/slogans.txt"

cp "$SCRIPT_DIR/compute-daily-cost.py" "$CLAUDE_DIR/compute-daily-cost.py"

SETTINGS_FILE="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
fi

if command -v jq &>/dev/null; then
    tmp=$(mktemp)
    jq --arg cmd "bash $CLAUDE_DIR/statusline-command.sh" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
    echo "Status line configured in $SETTINGS_FILE"
else
    echo "jq not found. Please add this to your $SETTINGS_FILE manually:"
    echo "  \"statusLine\": {\"type\": \"command\", \"command\": \"bash $CLAUDE_DIR/statusline-command.sh\"}"
fi

echo "Done! Restart Claude Code to see the new status line."
