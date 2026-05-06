---
name: "pr-cleanup"
description: "Find and close stale GitHub PRs. Surveys all open PRs for the authenticated user, identifies those with no activity beyond a configurable threshold (default 30 days), and bulk-closes them after confirmation."
---

# PR Cleanup — Close Stale Pull Requests

Find all open PRs authored by the authenticated GitHub user, identify
stale ones, and close them after user confirmation.

## Arguments

The user may pass a number of days as the staleness threshold.
Default is **30 days**. Examples:

- `/pr-cleanup` — PRs with no activity in 30+ days
- `/pr-cleanup 14` — PRs with no activity in 14+ days
- `/pr-cleanup 90` — PRs with no activity in 90+ days

## Procedure

### Step 1 — Identify the User

```bash
gh api user --jq '.login'
```

If this fails, stop and tell the user to authenticate with `gh auth login`.

### Step 2 — Fetch All Open PRs

```bash
gh search prs --author=<login> --state=open \
  --json repository,title,url,createdAt,updatedAt,state,number,isDraft \
  --limit 100
```

### Step 3 — Filter Stale PRs

Compare each PR's `updatedAt` against today's date minus the
staleness threshold. A PR is stale if it has had **no activity**
(no commits, comments, reviews, or label changes) within the
threshold period.

### Step 4 — Present Results

Show the user a summary with two sections:

**Active PRs** (within threshold) — brief count and list so the
user knows what's being kept.

**Stale PRs** (beyond threshold) — full table:

| # | Repo | Title | Last Activity |
|---|------|-------|---------------|

Sort stale PRs by last activity date, oldest first.

If there are no stale PRs, say so and stop.

### Step 5 — Confirm with the User

Ask the user what to do using `AskUserQuestion`:

- **Close all** — close every stale PR
- **Select which to keep** — let the user name PRs to exclude, then close the rest
- **Abort** — do nothing

Do NOT close any PRs without explicit user confirmation.

### Step 6 — Close PRs

For each PR to close, run:

```bash
gh pr close <number> --repo <owner/repo> \
  --comment "Closing — this PR has gone stale and is no longer being actively pursued. (Automated cleanup by agent)"
```

Run close commands in parallel (up to 10 at a time) for speed.

If a close fails with a transient error (HTTP 504, timeout), retry
once after a brief pause. If the retry also fails, report the
failure and continue with the remaining PRs.

### Step 7 — Report

After all closures complete, show a summary:

- How many PRs were closed
- Any failures
- How many open PRs remain
