#!/usr/bin/env python3
"""
compute-daily-cost.py  —  Estimate total Claude Code spend for today.

Usage:
    python3 compute-daily-cost.py <session_id> <current_session_cost_usd>

The script:
  1. Reads token usage from all ~/.claude/projects/**/*.jsonl files
     dated today (including subagent JSONL files).
  2. For the CURRENT session it uses <current_session_cost_usd> directly
     (the value from cost.total_cost_usd in the statusline JSON is exact).
  3. For ALL OTHER sessions it estimates cost using fixed per-token pricing
     calibrated for Sonnet 4.x.
  4. Results are cached in ~/.claude/daily-cost-cache.json for 90 seconds.
     The cache is invalidated when the date rolls over or when the set of
     JSONL files changes (tracked via a fingerprint of paths + mtimes).

Output: a single float printed to stdout, e.g.  2.3351
"""

import sys
import os
import json
import glob
import hashlib
import time
from datetime import datetime

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
CACHE_FILE = os.path.join(CLAUDE_DIR, "daily-cost-cache.json")
CACHE_TTL_SECONDS = 90

# Fixed per-token pricing (USD per token) for claude-sonnet-4-x.
# These are calibrated empirically and are intentionally stable — we never
# derive them dynamically from the current session's cost because that ratio
# shifts as cache-read tokens accumulate over a long session.
# Haiku and Opus pricing differ; for simplicity we use sonnet rates for all
# models (haiku slightly overestimates, Opus slightly underestimates).
PRICE_INPUT = 1.00e-6       # $1.00/MTok
PRICE_OUTPUT = 5.00e-6      # $5.00/MTok
PRICE_CACHE_CREATE = 1.25e-6  # $1.25/MTok
PRICE_CACHE_READ = 0.10e-6  # $0.10/MTok


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def estimate_cost(tokens: dict) -> float:
    """Return an estimated cost (USD) from a token-usage dict."""
    return (
        tokens.get("input_tokens", 0) * PRICE_INPUT
        + tokens.get("output_tokens", 0) * PRICE_OUTPUT
        + tokens.get("cache_creation_input_tokens", 0) * PRICE_CACHE_CREATE
        + tokens.get("cache_read_input_tokens", 0) * PRICE_CACHE_READ
    )


def is_today(ts_str: str, today: str) -> bool:
    """
    Return True if ts_str (ISO-8601 or YYYY-MM-DD prefix) belongs to today.
    today is 'YYYY-MM-DD' in local time.
    """
    if not ts_str:
        return False
    # Fast path: string starts with the date we want
    if ts_str.startswith(today):
        return True
    return False


def collect_jsonl_files(today_only: bool = False) -> list:
    """Return sorted list of all project JSONL files modified today (or ever)."""
    pattern = os.path.join(CLAUDE_DIR, "projects", "**", "*.jsonl")
    files = glob.glob(pattern, recursive=True)
    if today_only:
        today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        files = [f for f in files if os.path.getmtime(f) >= today_start]
    return sorted(files)


def fingerprint_files(files: list) -> str:
    """
    Return a short hash representing the current state of the file list.
    Uses path + mtime + size so we detect new files and new content quickly.
    """
    h = hashlib.md5()
    for path in files:
        try:
            st = os.stat(path)
            h.update(f"{path}:{st.st_mtime}:{st.st_size}\n".encode())
        except OSError:
            h.update(f"{path}:missing\n".encode())
    return h.hexdigest()


def parse_session_id_from_path(path: str) -> str:
    """
    Derive the top-level session ID from a JSONL path.

    Layout:
      ~/.claude/projects/<project>/<session_id>.jsonl          → session_id
      ~/.claude/projects/<project>/<session_id>/subagents/*.jsonl → session_id
    """
    parts = path.split(os.sep)
    try:
        projects_idx = parts.index("projects")
    except ValueError:
        return os.path.splitext(os.path.basename(path))[0]

    # parts after "projects": [<project>, ...]
    after = parts[projects_idx + 1:]  # [project, ...]
    if len(after) < 2:
        return os.path.splitext(os.path.basename(path))[0]

    # after[0] = project dir
    # after[1] = either "<session_id>.jsonl" or "<session_id>" (directory)
    candidate = after[1]
    if candidate.endswith(".jsonl"):
        return candidate[:-6]  # strip .jsonl
    # It's a directory (the subagent case): after[1] is the session_id dir
    return candidate


def aggregate_tokens_from_files(files: list, today: str) -> dict:
    """
    Scan JSONL files and return:
        { session_id: {"input_tokens": N, "output_tokens": N,
                       "cache_creation_input_tokens": N,
                       "cache_read_input_tokens": N} }

    Only assistant messages with a timestamp on today are counted.
    """
    sessions: dict = {}

    for path in files:
        session_id = parse_session_id_from_path(path)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for raw_line in fh:
                    raw_line = raw_line.strip()
                    if not raw_line:
                        continue
                    try:
                        entry = json.loads(raw_line)
                    except json.JSONDecodeError:
                        continue

                    # Must be an assistant message
                    if entry.get("type") != "assistant":
                        continue

                    # Check timestamp
                    ts = entry.get("timestamp", "")
                    if not is_today(ts, today):
                        continue

                    # Extract usage — may be at top level or inside message.usage
                    usage = entry.get("usage") or {}
                    if not usage:
                        msg = entry.get("message") or {}
                        usage = msg.get("usage") or {}

                    if not usage:
                        continue

                    if session_id not in sessions:
                        sessions[session_id] = {
                            "input_tokens": 0,
                            "output_tokens": 0,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                        }

                    for key in ("input_tokens", "output_tokens",
                                "cache_creation_input_tokens",
                                "cache_read_input_tokens"):
                        sessions[session_id][key] += usage.get(key, 0)

        except OSError:
            continue

    return sessions


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def compute_daily_cost(current_session_id: str, current_session_cost: float) -> float:
    today = datetime.now().strftime("%Y-%m-%d")

    # --- Collect JSONL files modified today ---
    all_files = collect_jsonl_files(today_only=True)
    fp = fingerprint_files(all_files)

    # --- Fast path: cache still fresh ---
    cache: dict = {}
    try:
        with open(CACHE_FILE, "r", encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, json.JSONDecodeError):
        pass

    cache_age = time.time() - cache.get("ts", 0)
    if (
        cache.get("date") == today
        and cache.get("fingerprint") == fp
        and cache_age < CACHE_TTL_SECONDS
    ):
        # Other sessions are fixed-price estimates; only the current session
        # changes between statusline calls. Swap it in for an exact value.
        other_cost = cache.get("other_sessions_cost", 0.0)
        return current_session_cost + other_cost

    # --- Full recomputation ---
    session_tokens = aggregate_tokens_from_files(all_files, today)

    # Sum other sessions using fixed pricing.  Current session always uses the
    # exact cost reported by Claude Code (cost.total_cost_usd is more accurate
    # than our fixed-price estimate).
    other_cost = sum(
        estimate_cost(tokens)
        for sid, tokens in session_tokens.items()
        if sid != current_session_id
    )

    total = current_session_cost + other_cost

    # --- Write cache ---
    try:
        cache_data = {
            "date": today,
            "fingerprint": fp,
            "ts": time.time(),
            "other_sessions_cost": other_cost,
        }
        tmp = CACHE_FILE + f".tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(cache_data, fh)
        os.replace(tmp, CACHE_FILE)
    except OSError:
        pass

    return total


def main():
    if len(sys.argv) < 3:
        print("Usage: compute-daily-cost.py <session_id> <current_cost_usd>", file=sys.stderr)
        sys.exit(1)

    session_id = sys.argv[1]
    try:
        current_cost = float(sys.argv[2])
    except ValueError:
        current_cost = 0.0

    result = compute_daily_cost(session_id, current_cost)
    # Print with enough precision for the bash script to format
    print(f"{result:.6f}")


if __name__ == "__main__":
    main()
