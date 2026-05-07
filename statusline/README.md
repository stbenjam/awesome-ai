# Claude Code Status Line

A colorful, information-dense status line for Claude Code that shows:

**Line 1** - Model, git branch (with dirty/staged indicators), and current directory

**Line 2** - Context window usage bar with color-coded warnings, session cost, daily cost across all sessions, duration, and lines changed

**Line 3** - Random inspirational slogan from a curated list of 381 messages

## Screenshot

```
✨ Claude Opus 4.6 │ 🌿 main● │ 📂 ~/projects/myapp
🧠 ▐████████░░░░░░░░░░░░▌ 40% │ 💰 $1.23 session │ 📅 $4.56 today │ ⏱️  12m │ 📝 +45 -12
💫 Ship it and sleep well
```

## Requirements

- `jq` (for parsing JSON input and configuring settings)
- `python3` (for daily cost tracking across sessions)
- A terminal with 256-color support

## Install

```bash
./install.sh
```

This copies the script and slogans to your Claude config directory (`$CLAUDE_CONFIG_DIR`, defaulting to `~/.claude/`) and configures your `settings.json`.

## Manual Install

1. Copy `statusline-command.sh` and `slogans.txt` to your Claude config directory (`$CLAUDE_CONFIG_DIR` or `~/.claude/`)
2. Add to your `settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /path/to/your/claude-config/statusline-command.sh"
  }
}
```

## Customization

- Edit `slogans.txt` to add your own motivational messages (one per line)
- Modify the color palette in `statusline-command.sh` (uses 256-color ANSI codes)
- Adjust the context bar width by changing `bar_width` (default: 20)
- Context usage thresholds: <50% green, <75% yellow, <85% orange, <95% red + warning, 95%+ blink
