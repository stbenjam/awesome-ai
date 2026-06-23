#!/bin/bash

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
ctx_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
ctx_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
ctx_window=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# ── Daily cost tracking ──
# Reads token usage from all today's JSONL session files and estimates cost
# using pricing calibrated from the current session's known cost.
# Falls back to current session cost if the Python script fails.
daily_cost=0
if [ -n "$session_id" ]; then
    daily_cost=$(python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/compute-daily-cost.py" \
        "$session_id" "${cost:-0}" 2>/dev/null) || daily_cost="${cost:-0}"
    # Ensure we have a numeric value
    if [ -z "$daily_cost" ] || ! printf '%f' "$daily_cost" >/dev/null 2>&1; then
        daily_cost="${cost:-0}"
    fi
fi

# Shorten home prefix to ~
home_dir="${HOME:-$(eval echo ~)}"
if [[ "$cwd" == "$home_dir"* ]]; then
    display_dir="~${cwd#"$home_dir"}"
else
    display_dir="$cwd"
fi

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

# Current user
current_user="${USER:-$(whoami 2>/dev/null)}"
user_str="${SEP}${PINK}👤 ${WHITE}${current_user}${RST}"

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

printf '%b\n' "${model_str}${user_str}${git_str}${dir_str}"

# ── Line 2: Context bar / Cost / Duration / Lines ──

used_int=$(printf "%.0f" "$used_pct")

# Format token count as human-readable (e.g. 104k, 1.0M)
fmt_tokens() {
    local n=$1
    if [ "$n" -ge 1000000 ]; then
        awk -v n="$n" 'BEGIN { printf "%.1fM", n/1000000 }'
    elif [ "$n" -ge 1000 ]; then
        awk -v n="$n" 'BEGIN { printf "%.0fk", n/1000 }'
    else
        printf '%s' "$n"
    fi
}

ctx_used=$((ctx_input + ctx_output))
ctx_used_fmt=$(fmt_tokens "$ctx_used")
ctx_window_fmt=$(fmt_tokens "$ctx_window")

bar_width=20
filled=$((used_int * bar_width / 100))
empty=$((bar_width - filled))

# Background color codes (matching foreground palette)
BG_TEAL='\033[48;5;43m'
BG_YELLOW='\033[48;5;221m'
BG_ORANGE='\033[48;5;209m'
BG_RED='\033[48;5;197m'
BLACK='\033[38;5;16m'
ROSE='\033[38;5;225m'
BG_GRAY='\033[48;5;239m'

# Color gradient + emoji based on usage
if [ "$used_int" -lt 50 ]; then
    BAR_COLOR="$TEAL";  BAR_BG="$BG_TEAL";  BAR_TEXT="$BLACK"
    PCT_COLOR="$GREEN"
    ctx_icon="🧠"
elif [ "$used_int" -lt 75 ]; then
    BAR_COLOR="$YELLOW"; BAR_BG="$BG_YELLOW"; BAR_TEXT="$BLACK"
    PCT_COLOR="$YELLOW"
    ctx_icon="🧠"
elif [ "$used_int" -lt 85 ]; then
    BAR_COLOR="$ORANGE"; BAR_BG="$BG_ORANGE"; BAR_TEXT="$BLACK"
    PCT_COLOR="$ORANGE"
    ctx_icon="🔥"
elif [ "$used_int" -lt 95 ]; then
    BAR_COLOR="$RED"; BAR_BG="$BG_RED"; BAR_TEXT="$ROSE"
    PCT_COLOR="$RED"
    ctx_icon="⚠️"
    warning="${SEP}${RED}${BOLD}⚠️  COMPACT SOON${RST}"
else
    BAR_COLOR="$RED"; BAR_BG="$BG_RED"; BAR_TEXT="$ROSE"
    PCT_COLOR="$RED"
    ctx_icon="🚨"
    warning="${SEP}${RED}${BOLD}${BLINK}🚨 COMPACTING${RST}"
fi

label="${ctx_used_fmt}/${ctx_window_fmt}"
label_len=${#label}
pad_left=$(( (bar_width - label_len) / 2 ))

bar=""
for ((i=0; i<bar_width; i++)); do
    if [ $i -ge $pad_left ] && [ $((i - pad_left)) -lt $label_len ]; then
        char="${label:$((i - pad_left)):1}"
        if [ $i -lt $filled ]; then
            bar="${bar}${BAR_BG}${BAR_TEXT}${BOLD}${char}${RST}"
        else
            bar="${bar}${BG_GRAY}${WHITE}${BOLD}${char}${RST}"
        fi
    else
        if [ $i -lt $filled ]; then
            bar="${bar}${BAR_COLOR}█${RST}"
        else
            bar="${bar}${GRAY}░${RST}"
        fi
    fi
done

ctx_str="${ctx_icon} ${GRAY}▐${RST}${bar}${GRAY}▌${RST} ${PCT_COLOR}${BOLD}${used_int}%${RST}${warning}"

# Cost — session and daily
cost_fmt=$(printf '$%.2f' "${cost:-0}")
daily_fmt=$(printf '$%.2f' "${daily_cost:-0}")
cost_str="${SEP}${GREEN}💰 ${cost_fmt}${RST}${DIM}${GRAY} session${RST}${SEP}${YELLOW}📅 ${daily_fmt}${RST}${DIM}${GRAY} today${RST}"

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
