#!/bin/bash

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Shorten home prefix to ~
display_dir="${cwd/#$HOME/~}"

# Colors — 256-color palette for vibrancy
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
BLINK='\033[5m'

# Sparkle/accent colors
PINK='\033[38;5;213m'
HOTPINK='\033[38;5;198m'
PURPLE='\033[38;5;141m'
CYAN='\033[38;5;87m'
BLUE='\033[38;5;75m'
TEAL='\033[38;5;43m'
GREEN='\033[38;5;114m'
LIME='\033[38;5;155m'
YELLOW='\033[38;5;221m'
ORANGE='\033[38;5;209m'
RED='\033[38;5;197m'
GRAY='\033[38;5;243m'
WHITE='\033[38;5;255m'

# Separator
SEP="${DIM}${PURPLE} │ ${RST}"

# ── Line 1: Model / Git / Directory ──

model_str="${HOTPINK}${BOLD}✨${RST} ${CYAN}${BOLD}${model}${RST}"

# Git info
git_str=""
if cd "$cwd" 2>/dev/null && git rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        staged=""
        dirty=""
        if ! git diff --cached --quiet 2>/dev/null; then
            staged="${LIME}+${RST}"
        fi
        if ! git diff --quiet 2>/dev/null; then
            dirty="${YELLOW}●${RST}"
        fi
        marks="${staged}${dirty}"
        if [ -n "$marks" ]; then
            marks=" ${marks}"
        fi
        git_str="${SEP}${PURPLE}🌿 ${branch}${RST}${marks}"
    fi
fi

# Directory — full path with ~ for home
dir_str="${SEP}${BLUE}📂 ${display_dir}${RST}"

printf '%b\n' "${model_str}${git_str}${dir_str}"

# ── Line 2: Context bar / Cost / Duration / Lines ──

used_int=$(printf "%.0f" "$used_pct")
bar_width=20
filled=$((used_int * bar_width / 100))
empty=$((bar_width - filled))

# Color gradient + emoji based on usage
if [ "$used_int" -lt 50 ]; then
    BAR_COLOR="$TEAL"
    PCT_COLOR="$GREEN"
    ctx_icon="🧠"
elif [ "$used_int" -lt 75 ]; then
    BAR_COLOR="$YELLOW"
    PCT_COLOR="$YELLOW"
    ctx_icon="🧠"
elif [ "$used_int" -lt 85 ]; then
    BAR_COLOR="$ORANGE"
    PCT_COLOR="$ORANGE"
    ctx_icon="🔥"
elif [ "$used_int" -lt 95 ]; then
    BAR_COLOR="$RED"
    PCT_COLOR="$RED"
    ctx_icon="⚠️"
    warning="${SEP}${RED}${BOLD}⚠️  COMPACT SOON${RST}"
else
    BAR_COLOR="$RED"
    PCT_COLOR="$RED"
    ctx_icon="🚨"
    warning="${SEP}${RED}${BOLD}${BLINK}🚨 COMPACTING${RST}"
fi

bar="${BAR_COLOR}"
for ((i=0; i<filled; i++)); do bar="${bar}█"; done
bar="${bar}${RST}${GRAY}"
for ((i=0; i<empty; i++)); do bar="${bar}░"; done
bar="${bar}${RST}"

ctx_str="${ctx_icon} ${GRAY}▐${RST}${bar}${GRAY}▌${RST} ${PCT_COLOR}${BOLD}${used_int}%${RST}${warning}"

# Cost
cost_fmt=$(printf '$%.2f' "${cost:-0}")
cost_str="${SEP}${GREEN}💰 ${cost_fmt}${RST}"

# Duration
dur_str=""
if [ -n "$duration_ms" ] && [ "$duration_ms" != "0" ]; then
    total_sec=$((duration_ms / 1000))
    if [ "$total_sec" -ge 3600 ]; then
        hrs=$((total_sec / 3600))
        mins=$(( (total_sec % 3600) / 60 ))
        dur_str="${SEP}${GRAY}⏱️  ${hrs}h${mins}m${RST}"
    elif [ "$total_sec" -ge 60 ]; then
        mins=$((total_sec / 60))
        dur_str="${SEP}${GRAY}⏱️  ${mins}m${RST}"
    else
        dur_str="${SEP}${GRAY}⏱️  ${total_sec}s${RST}"
    fi
fi

# Lines changed
lines_str=""
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
    lines_str="${SEP}${LIME}📝 +${lines_added}${RST} ${RED}-${lines_removed}${RST}"
fi

printf '%b\n' "${ctx_str}${cost_str}${dur_str}${lines_str}"

# ── Line 3: Inspirational slogan ──

SLOGANS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/slogans.txt"
if [ -f "$SLOGANS_FILE" ]; then
    total=$(wc -l < "$SLOGANS_FILE")
    line=$(( (RANDOM % total) + 1 ))
    slogan=$(sed -n "${line}p" "$SLOGANS_FILE")
    printf '%b' "${DIM}${PINK}💫 ${PURPLE}${slogan}${RST}"
fi
