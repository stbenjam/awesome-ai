#!/usr/bin/env python3
"""Gather open PR data and trusted reviewer comments, output JSON for the pr-monitor skill."""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

TRUSTED_ASSOCIATIONS = {"COLLABORATOR", "OWNER", "MEMBER"}
DEFAULT_ALLOWLIST = ["coderabbitai[bot]"]
STALE_DAYS = 30
RATE_LIMIT_SLEEP = 0.5


def gh(*args, parse_json=True):
    result = subprocess.run(
        ["gh", *args],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    if not parse_json:
        return result.stdout.strip()
    return json.loads(result.stdout) if result.stdout.strip() else []


def gh_api_paginated(endpoint):
    pages = []
    page = 1
    while True:
        sep = "&" if "?" in endpoint else "?"
        data = gh("api", f"{endpoint}{sep}per_page=100&page={page}")
        if not data:
            break
        pages.extend(data)
        if len(data) < 100:
            break
        page += 1
        time.sleep(RATE_LIMIT_SLEEP)
    return pages


def get_user():
    data = gh("api", "user")
    return data["login"]


def fetch_open_prs(login):
    raw = gh(
        "search", "prs",
        f"--author={login}", "--state=open",
        "--json", "repository,title,url,createdAt,updatedAt,number,isDraft",
        "--limit", "100",
    )
    prs = []
    for pr in raw:
        repo = pr["repository"]["nameWithOwner"]
        prs.append({
            "number": pr["number"],
            "repo": repo,
            "title": pr["title"],
            "url": pr["url"],
            "created_at": pr["createdAt"],
            "updated_at": pr["updatedAt"],
            "is_draft": pr["isDraft"],
        })
    return prs


def load_tracking(data_dir):
    path = data_dir / "tracking.json"
    if path.exists():
        return json.loads(path.read_text())
    return {"prs": {}}


def load_allowlist(data_dir):
    entries = set(DEFAULT_ALLOWLIST)
    path = data_dir / "allowlist.txt"
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                entries.add(line)
    env_extra = os.environ.get("PR_MONITOR_ALLOWLIST", "")
    if env_extra:
        for entry in env_extra.split(","):
            entry = entry.strip()
            if entry:
                entries.add(entry)
    return entries


def is_trusted(comment, allowlist):
    assoc = comment.get("author_association", "")
    login = comment.get("user", {}).get("login", "")
    return assoc in TRUSTED_ASSOCIATIONS or login in allowlist


def parse_dt(s):
    s = s.replace("Z", "+00:00")
    return datetime.fromisoformat(s)


def fetch_comments(repo, number, last_checked, allowlist):
    since_dt = parse_dt(last_checked) if last_checked else None
    comments = []

    for endpoint, comment_type in [
        (f"repos/{repo}/issues/{number}/comments", "issue_comment"),
        (f"repos/{repo}/pulls/{number}/comments", "review_comment"),
    ]:
        try:
            raw = gh_api_paginated(endpoint)
        except RuntimeError:
            continue
        for c in raw:
            created = c.get("created_at", "")
            if since_dt and parse_dt(created) <= since_dt:
                continue
            if not is_trusted(c, allowlist):
                continue
            comments.append({
                "author": c.get("user", {}).get("login", "unknown"),
                "author_association": c.get("author_association", ""),
                "body": c.get("body", ""),
                "created_at": created,
                "url": c.get("html_url", ""),
                "id": c.get("id"),
                "type": comment_type,
            })
        time.sleep(RATE_LIMIT_SLEEP)

    comments.sort(key=lambda c: c["created_at"])
    return comments


def check_agent_commands(repo, number, user_login):
    try:
        all_comments = gh_api_paginated(f"repos/{repo}/issues/{number}/comments")
    except RuntimeError:
        return "monitor", None

    pattern = re.compile(r"/agent-(ignore|monitor)\b")
    status = "monitor"
    comment_id = None

    for c in all_comments:
        author = c.get("user", {}).get("login", "")
        if author != user_login:
            continue
        match = pattern.search(c.get("body", ""))
        if match:
            status = match.group(1)
            comment_id = c.get("id")

    return status, comment_id


def compute_staleness(updated_at):
    updated = parse_dt(updated_at)
    now = datetime.now(timezone.utc)
    days = (now - updated).days
    return days, days > STALE_DAYS


def process_pr(pr, tracking, allowlist, user_login):
    repo = pr["repo"]
    number = pr["number"]
    key = f"{repo}#{number}"

    tracked = tracking.get("prs", {}).get(key, {})
    last_checked = tracked.get("last_checked")

    status, cmd_comment_id = check_agent_commands(repo, number, user_login)

    if status == "ignore":
        return {
            **pr,
            "status": "ignore",
            "agent_command_comment_id": cmd_comment_id,
            "stale": False,
            "days_inactive": 0,
            "new_comments": [],
        }

    days, stale = compute_staleness(pr["updated_at"])
    new_comments = fetch_comments(repo, number, last_checked, allowlist)

    return {
        **pr,
        "status": status,
        "agent_command_comment_id": cmd_comment_id,
        "stale": stale,
        "days_inactive": days,
        "new_comments": new_comments,
    }


def main():
    parser = argparse.ArgumentParser(description="PR Monitor data gatherer")
    parser.add_argument("--data-dir", required=True, help="Path to pr-monitor data directory")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)

    try:
        user_login = get_user()
    except RuntimeError as e:
        print(json.dumps({"error": f"Auth failed: {e}"}), file=sys.stderr)
        sys.exit(1)

    tracking = load_tracking(data_dir)
    allowlist = load_allowlist(data_dir)
    open_prs = fetch_open_prs(user_login)

    results = []
    for i, pr in enumerate(open_prs):
        try:
            result = process_pr(pr, tracking, allowlist, user_login)
            results.append(result)
        except RuntimeError as e:
            results.append({**pr, "error": str(e), "status": "error", "new_comments": []})
        if i < len(open_prs) - 1:
            time.sleep(RATE_LIMIT_SLEEP)

    output = {
        "user": user_login,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "prs": results,
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
