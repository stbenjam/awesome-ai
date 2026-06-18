---
name: "deep-review"
description: "Multi-agent panel code review with forced runtime reproducers for all bug findings. Produces an interactive HTML report walking through changes and findings. Optionally posts to GitHub/GitLab as a PENDING review."
argument-hint: "[-supply-chain,-codex,...] [pr-url]"
---

# Deep Review — Multi-Agent Panel Review with Reproducers

Review a branch's changes with parallel subagent reviewers, each
with a different focus. Verify every bug with a runtime reproducer.
Produce an interactive HTML report that walks through the changes
and findings. Optionally post to GitHub/GitLab as a PENDING review.

No PR/MR is required — the review works on any branch with commits
ahead of its base.

## Arguments

```
/deep-review [modifiers] [pr-url]
```

All reviewer types are enabled by default. Use `-` prefix to exclude:

| Argument | Description |
|----------|-------------|
| modifiers | Comma-separated. Prefix with `-` to exclude a default reviewer (e.g., `-supply-chain,-codex`) |
| pr-url | GitHub or GitLab PR/MR URL. Optional — enables posting review comments to the PR |

Examples:

- `/deep-review` — all reviewers, review current branch
- `/deep-review -codex` — skip the codex CLI reviewer
- `/deep-review -supply-chain https://github.com/org/repo/pull/42`
- `/deep-review https://gitlab.com/org/repo/-/merge_requests/7`

### Default Reviewer Types

All are enabled unless excluded with `-`:

| Type | Focus | Reproducer Required? |
|------|-------|---------------------|
| **bugs** | Functional bugs: missing calls, wrong logic, unhandled edge cases | Yes — mandatory |
| **adversarial** | Break the code: bad inputs, race conditions, boundary values | Yes — mandatory |
| **correctness** | Contract/spec compliance, inherited behavior gaps, test accuracy | When claiming a bug |
| **supply-chain** | New deps, lockfile changes, typosquatting, credential exposure | No |
| **codex** | Run OpenAI `codex review` CLI externally | No |
| **coderabbit** | Code quality, patterns, best practices, regressions | When claiming a bug |
| **architecture** | Design decisions, coupling, API surface, extensibility | No |

## Procedure

### Phase 1 — Setup

#### Step 1.1: Parse arguments

Parse the argument string:
- Tokens starting with `-` followed by a reviewer name exclude
  that reviewer from the default set (e.g., `-codex`)
- A token containing `github.com/…/pull/` or `gitlab.com/…/merge_requests/`
  is the PR/MR URL — this is optional and only used for posting
- All reviewers are enabled by default; only `-` prefixed names
  remove them

#### Step 1.2: Determine the branch and merge base

If a PR/MR URL was provided, check out that PR locally:

**GitHub:** `gh pr checkout $PR_NUMBER`
**GitLab:** `glab mr checkout $MR_IID`

Determine the base branch. In order of preference:
1. If a PR/MR is known, use its base ref
2. Otherwise, use the default branch (`main` or `master`)

Fetch and compute the merge base:

```bash
git fetch origin $BASE_REF
MERGE_BASE=$(git merge-base origin/$BASE_REF HEAD)
```

This merge base is used for all diffs throughout the review.

#### Step 1.3: Get the diff and changed files

```bash
git diff $MERGE_BASE...HEAD > /tmp/deep-review-diff.patch
git diff $MERGE_BASE...HEAD --name-only
```

If a PR/MR exists, also fetch its description for context.

If the diff is empty, stop: "No changes found between HEAD and
the base branch."

### Phase 2 — Familiarization

Before dispatching reviewers, examine the codebase and present the
user a summary of what's changing.

#### Step 2.1: Summarize the changes

Read the diff and the changed files in context. Present a concise
summary to the user:

- What areas of the codebase are affected
- The nature of the changes (new feature, bug fix, refactor, etc.)
- Key design decisions visible in the diff

#### Step 2.2: Offer local testing

If the changes are testable locally (e.g., a feature with tests,
a bug fix with a repro case, a CLI change, a library with a test
suite), offer to run the test suite or manually test the feature
before proceeding to the review.

If the changes are NOT locally testable (infrastructure-only,
CI config, documentation, etc.), note this.

**Ask the user** before testing — do not just do it. The user may
already be familiar with the changes (second or third round review)
and want to skip straight to the panel.

**If the conversation context shows a previous familiarization pass
on this same branch, skip this phase entirely.**

### Phase 3 — Dispatch Reviewers

Launch one subagent per enabled reviewer type, **all in parallel**,
using the Agent tool with `run_in_background: true`.

Tell every subagent the merge base so they diff correctly:
`git diff $MERGE_BASE...HEAD` (not `gh pr diff`).

Every reviewer subagent MUST return its findings as a JSON array
in a fenced `json` code block at the end of its response:

```json
[
  {
    "file": "src/example.py",
    "line": 42,
    "severity": "bug",
    "title": "Short title",
    "body": "Description of the issue",
    "suggestion": "One-line fix suggestion or null",
    "reproducer_needed": true
  }
]
```

**Severity values**: `bug` | `potential` | `security` | `style` |
`architecture` | `info`

#### Reviewer prompts

Each reviewer subagent gets the merge base ref, changed file list,
and full access to the locally checked-out codebase.

---

**bugs** reviewer:

> You are a meticulous code reviewer focused exclusively on finding
> FUNCTIONAL BUGS in a pull request.
>
> **Your focus**: Missing function calls or initialization. Wrong
> logic (inverted conditions, off-by-one, wrong operator). Unhandled
> edge cases (nil/null, empty collections, zero values). Race
> conditions. Resource leaks. Error handling gaps. Type mismatches.
> Contract violations (caller passes wrong args, callee returns
> unexpected values). Inherited methods that don't work in the
> subclass context.
>
> **Ignore**: Style, formatting, naming. "Could be improved"
> suggestions. Test coverage gaps (unless a test is WRONG).
> Documentation.
>
> **Method**: Run `git diff {MERGE_BASE}...HEAD` for the full diff.
> For each changed file, read the FULL file (not just the diff) to
> understand context. Trace code paths — follow function calls,
> check callers and callees, check base class methods that are
> inherited but not overridden. For each bug found, set
> `reproducer_needed: true`.

---

**adversarial** reviewer:

> You are an adversarial code reviewer. Your job is to BREAK the
> code in this pull request. Think like a malicious user, a chaos
> monkey, or a fuzzer.
>
> **Your focus**: Inputs that cause panics or crashes. State
> sequences that lead to corruption. Boundary values (max int,
> empty string, null, NaN, negative). Concurrent access patterns
> that race. Malformed data that bypasses validation. Resource
> exhaustion (unbounded allocations, infinite loops). Injection
> vectors (shell, SQL, templates).
>
> **For each changed function**: What are the WORST inputs? What
> state assumptions could be violated? What happens if called
> twice, concurrently, or out of order? What happens at boundaries?
>
> Run `git diff {MERGE_BASE}...HEAD` for the full diff. Read full
> source files for context. Set `reproducer_needed: true` for every
> finding.

---

**correctness** reviewer:

> You are a correctness reviewer. Verify the code does what it
> claims — check against docs, tests, interface contracts, and
> inherited behavior.
>
> **Your focus**: Does the implementation match the PR description?
> Do new methods satisfy interface contracts? Are overridden methods
> compatible with base class expectations? Do tests actually test
> what they claim? Are error messages accurate? Are comments still
> true? Do config defaults match docs?
>
> Run `git diff {MERGE_BASE}...HEAD` for the full diff. For
> findings that claim a concrete bug, set `reproducer_needed: true`.
> For spec/contract mismatches, set severity to `potential`.

---

**supply-chain** reviewer:

> You are a supply-chain security reviewer.
>
> **Your focus**: New dependencies — check names for typosquatting.
> Lockfile changes — unexpected version bumps, new transitive deps.
> Build script modifications — download URLs, curl|bash, post-install
> scripts. Container image changes — unverified registries, tag
> mutability. GitHub Actions / GitLab CI changes — new third-party
> actions, version unpinning. Credential exposure — API keys, tokens
> in code.
>
> Run `git diff {MERGE_BASE}...HEAD` for the full diff. Set
> `reproducer_needed: false` for all findings. Set severity to
> `security` for confirmed risks.

---

**codex** reviewer:

This reviewer does NOT use a subagent prompt. Run the CLI directly:

```bash
git diff $MERGE_BASE...HEAD | codex review -
```

Parse the output and normalize each finding to the standard JSON
format. Set `reproducer_needed: false` and severity to `potential`.

If `codex` is not installed or fails, warn the user and skip this
reviewer. Do not fail the entire review.

---

**coderabbit** reviewer:

> You are a CodeRabbit-style code reviewer focused on code quality,
> patterns, best practices, and potential regressions.
>
> **Your focus**: Anti-patterns and code smells. Missing error
> handling (practical, not pedantic). Performance regressions
> (O(n^2) where O(n) suffices). API design issues. Backward
> compatibility breaks. Inconsistency with surrounding code
> patterns. Test quality (flaky patterns, missing assertions).
>
> Run `git diff {MERGE_BASE}...HEAD` for the full diff. For findings
> claiming a concrete bug or regression, set `reproducer_needed:
> true`. For quality issues, set severity to `style`.

---

**architecture** reviewer:

> You are an architecture reviewer evaluating structural and design
> decisions.
>
> **Your focus**: Abstraction boundaries — is responsibility clearly
> divided? Coupling — does this create tight coupling? API surface
> — is the public interface minimal? Extensibility — easy to modify
> later? Separation of concerns. Consistency with project patterns.
>
> Run `git diff {MERGE_BASE}...HEAD` for the full diff. Set severity
> to `architecture` for all findings. Set `reproducer_needed: false`.
> Focus on decisions costly to change.

### Phase 4 — Reproduce

After all reviewer subagents complete, collect their findings.

For every finding where `reproducer_needed` is `true` AND severity
is `bug`, `security`, or `potential`:

Launch a **reproducer subagent** (up to 5 in parallel, 10 minute
timeout each). Each gets this prompt:

> Create and execute a minimal reproducer to verify this bug.
>
> **Finding**: {title} in {file}:{line} — {body}
>
> **Instructions**:
> 1. Read the file and surrounding code for full context
> 2. Design the SMALLEST test case that demonstrates the bug
> 3. Create the reproducer files (scripts, configs, inputs)
> 4. Execute it and capture the output
> 5. Report pass (bug confirmed) or fail (not reproduced)
>
> **Requirements**:
> - Must be runnable, not a thought experiment
> - Must produce a clear pass/fail result
> - If the bug requires infrastructure you can't create locally,
>   explain why and report `not_reproducible`
> - Do not run destructive operations outside /tmp
> - Clean up temp files when done
>
> Return a JSON object in a fenced `json` block:
> ```json
> {
>   "reproduced": true,
>   "explanation": "What happened",
>   "steps": "Exact commands and files",
>   "expected": "Correct behavior",
>   "actual": "What actually happened (real output)",
>   "files": [{"path": "name", "content": "..."}]
> }
> ```

#### Processing results

- `reproduced: true` — keep severity, attach reproducer details
- `reproduced: false` — downgrade severity to `potential`, add
  note: "Reproducer did not confirm this bug — may be a false
  positive or require conditions not tested."
- `reproduced: "not_reproducible"` — keep severity, add note
  explaining why

### Phase 5 — Arbiter

Before producing the report, act as an arbiter over all reviewer
outputs. Review every finding from every reviewer and decide what
to include.

#### Step 5.1: Deduplicate

Multiple reviewers may find the same issue. Merge duplicates,
keeping the most detailed description and the strongest reproducer.

#### Step 5.2: Filter noise

Remove findings that are:
- Clearly false positives (contradicted by code the reviewer missed)
- Style nitpicks that don't match the project's conventions
- Speculative ("this could be a problem if...") without evidence
- Already addressed elsewhere in the branch (e.g., in a later commit)

#### Step 5.3: Prioritize

Rank remaining findings by severity and impact:
1. Reproduced bugs with security implications
2. Reproduced functional bugs
3. Unreproduced but plausible bugs (downgraded to `potential`)
4. Architecture/design concerns
5. Style and quality notes

#### Step 5.4: Write the verdict

Synthesize a verdict — the arbiter's final opinion:

1. **Disposition**: Approve | Approve with nits | Request changes | Reject
2. **Summary**: 2-3 sentences on what the changes do and whether
   the approach is sound
3. **Key findings**: The most important issues, one-line each
4. **What's good**: Briefly acknowledge solid work
5. **Recommendation**: What the author should do next

#### Step 5.5: Present arbiter summary

Show the user the curated findings before generating the report:

```
Arbiter summary: N findings from M reviewers.
Kept: X bugs (Y reproduced), Z style/arch notes.
Dropped: W duplicates, V false positives.
Verdict: {disposition}
```

Proceed to Phase 6 unless the user objects.

### Phase 6 — Generate HTML Report

Produce a self-contained interactive HTML report and write it to
the repo root as `deep-review.html`. Then open it in the browser.

The report is a **single HTML file** with all CSS and JS inlined —
no external dependencies, no CDN links. It must work offline when
opened as a local file.

#### Report structure

The report has three main areas:

**1. Sidebar (left, fixed)**

- Branch name and date
- Verdict badge (color-coded: green/yellow/orange/red)
- Summary stats: files changed, findings count by severity
- File list — each file shows its finding count as a badge.
  Clicking a file scrolls the main area to that file's section.
  Files with bug findings are highlighted
- Finding index — a flat list of all findings by severity,
  clickable to jump to each one

**2. Header (top of main area)**

- Verdict section: disposition, summary, recommendation
- Key findings table
- "What's good" section
- Expandable: full reviewer breakdown (which reviewers ran,
  how many findings each produced, timing)

**3. Main area (scrollable, per-file sections)**

For each changed file, in the order they appear in the diff:

- **File header**: filename, lines added/removed, finding count
- **Diff view**: the unified diff with syntax-highlighted code.
  Line numbers for both old and new file shown in gutters
- **Inline annotations**: findings appear as colored callout boxes
  anchored to the relevant diff line. Color by severity:
  - Red: `bug`, `security`
  - Orange: `potential`
  - Blue: `style`, `architecture`
  - Gray: `info`
- Each annotation shows:
  - Severity badge and title
  - Description
  - Suggested fix (if any)
  - Which reviewer(s) found it
  - **Reproducer** (collapsible): steps, expected, actual,
    files — with code blocks and copy buttons
  - **Feedback controls** (see below)
- **Annotation markers in the diff gutter**: small colored dots
  on lines that have findings, so you can spot them while
  scrolling the diff

**4. Footer**

- Reviewers used, timestamp, merge base ref
- Export feedback button
- "Generated by /deep-review"

#### Feedback controls (screener loop)

Each finding annotation includes interactive feedback controls
that let the reviewer respond to the finding. This enables a
feedback loop: review → correct → re-evaluate → repeat.

**Per-finding controls:**

- **Verdict buttons**: Agree / Disagree / Needs revision — one
  click, visually highlighted when selected
- **Severity override**: dropdown to reclassify (e.g., change
  `bug` to `style` or `info`)
- **Notes field**: freeform text area for the reviewer to explain
  WHY they agree/disagree. These notes are critical — they encode
  patterns the AI can generalize. Examples:
  - "This is actually handled by the base class at line 200"
  - "The race condition is prevented by the lock acquired in the
    caller — grep for `_lock.acquire` in `scheduler.py`"
  - "Not a bug — this is intentional defensive coding per our
    style guide"
- **Resolved checkbox**: mark a finding as addressed (dims it
  visually but keeps it in the export)

All feedback state persists in the browser via `localStorage`
keyed by the report's branch + timestamp, so the reviewer can
close the tab and come back.

**Global controls (in the header):**

- **Export Feedback** button: serializes all feedback (verdicts,
  severity overrides, notes, resolved state) as a JSON blob.
  Two export options:
  - **Copy to clipboard** — for pasting directly into the Claude
    Code session
  - **Save to file** — writes `deep-review-feedback.json` to
    the repo root
- **Stats bar**: "N/M findings reviewed, X agreed, Y disagreed,
  Z need revision"
- **Jump to next unreviewed**: button that scrolls to the next
  finding without a verdict

**Export format:**

```json
{
  "branch": "feature/xyz",
  "merge_base": "abc123",
  "reviewed_at": "2026-06-18T17:00:00Z",
  "findings": [
    {
      "id": "f1",
      "file": "src/foo.py",
      "line": 42,
      "title": "Missing null check",
      "verdict": "disagree",
      "severity_override": "info",
      "note": "Handled by the caller — see guard at line 38",
      "resolved": false
    }
  ]
}
```

#### Interactivity (navigation)

- **Filter by severity**: toggle buttons at the top to show/hide
  findings by severity level
- **Filter by verdict**: show only agreed / disagreed / unreviewed
- **Collapse/expand all**: button to collapse or expand all
  reproducer details and file sections
- **Keyboard navigation**: `j`/`k` to jump between findings,
  `f` to jump between files, `Escape` to return to top,
  `a`/`d`/`r` to agree/disagree/needs-revision on the focused
  finding
- **Search**: simple text search across finding titles and
  descriptions
- **Sticky file header**: the current file's name stays visible
  when scrolling through a long diff
- **Dark/light mode**: toggle, defaulting to system preference

#### Diff rendering

Render the diff as a standard unified diff view:
- Green background for added lines (`+`)
- Red background for removed lines (`-`)
- No background for context lines
- Line numbers in both old-file and new-file gutters
- Monospace font throughout
- Wrap long lines (do not horizontal scroll)

Use basic syntax highlighting if possible (keywords, strings,
comments) based on the file extension. Keep it simple — a few
regex rules per language, not a full parser.

#### Writing the report

Use the template at `template.html` (in this skill's directory) as
the starting point. Replace the `{{PLACEHOLDER}}` tokens with real
data from the review. The template provides the full CSS, JS, and
layout — populate it with the actual diff, findings, reproducers,
verdict, and file list.

Key placeholders to replace:
- `{{BRANCH_NAME}}` — branch or PR name
- `{{REVIEW_DATE}}` — ISO date string
- `{{VERDICT_DISPOSITION}}` — Approve / Request Changes / etc.
- `{{VERDICT_SUMMARY}}` — arbiter's summary text
- `{{PR_TITLE}}` — PR title or branch description
- `{{WHATS_GOOD}}` — positive observations
- `{{RECOMMENDATION}}` — next steps for the author
- `{{MERGE_BASE}}` — the merge base commit ref
- `{{FILES_CHANGED}}`, `{{TOTAL_FINDINGS}}`, `{{BUG_COUNT}}`,
  `{{REPRODUCED_COUNT}}` — numeric stats
- `{{FILE_LIST}}` — sidebar file entries (see template for format)
- `{{FINDINGS_INDEX}}` — sidebar finding entries
- `{{FINDINGS_TABLE_ROWS}}` — verdict table rows

For each file, generate a `<section class="file-section">` with:
- The diff rendered as `<table class="diff-table">` rows
- Annotation `<div class="annotation {severity}">` blocks
  inserted after the relevant diff line, each with feedback
  controls

Write the final HTML to `deep-review.html` in the repo root.

Then open it:

```bash
# macOS
open deep-review.html
# Linux
xdg-open deep-review.html
```

Tell the user: "Report written to `deep-review.html` and opened
in your browser. Review the findings, add your feedback, then
export and paste it back here — or say 'post to PR' when ready."

### Phase 7 — Feedback Loop (Screener Pattern)

When the user pastes exported feedback JSON (from the report's
Export button) or says to read `deep-review-feedback.json`:

#### Step 7.1: Ingest feedback

Parse the feedback JSON. For each finding:

- **Agreed findings**: keep as-is
- **Disagreed findings**: read the reviewer's note carefully.
  The note explains WHY — this is domain knowledge. Generalize
  the pattern:
  - If the note says "handled by X", verify X exists and does
    handle it. If confirmed, drop the finding
  - If the note describes a project convention, apply it to
    similar findings across the entire set
  - If the note identifies a false-positive pattern ("we
    intentionally do X because Y"), scan for other findings
    that match the same pattern and drop them too
- **Needs revision**: re-examine the finding in light of the
  note and revise the description, severity, or suggestion
- **Severity overrides**: accept the reviewer's reclassification
- **Resolved**: keep in the report but dim/collapse

#### Step 7.2: Re-evaluate

Based on the patterns extracted from reviewer feedback:

1. Re-check all remaining findings (not just the ones with
   feedback) against the newly learned patterns
2. Drop findings that match a disagreed pattern
3. Adjust severities where the reviewer's notes apply broadly
4. Potentially spawn targeted re-review subagents for areas
   the reviewer flagged as needing deeper analysis

#### Step 7.3: Regenerate report

Produce a new `deep-review.html` with:
- Updated findings (dropped, revised, reclassified)
- A "Changes from feedback" section showing what was modified
- Previous feedback preserved in the UI (so the reviewer can
  see their notes are reflected)
- Any new findings from re-evaluation clearly marked as "New"

Open the regenerated report. The reviewer can do another round
of feedback if needed. Repeat until stable.

#### Step 7.4: Summary

After the loop stabilizes, present:

```
Feedback loop complete.
  Round 1: N findings → M after feedback
  Round 2: M findings → K after feedback (if applicable)
  Final: K findings (X bugs, Y style, Z arch)
```

### Phase 9 — Post to PR (Optional)

This phase runs ONLY if a PR/MR URL was provided or detected.
After the user has reviewed the HTML report, offer to also post
the findings as inline review comments on the PR.

**Ask the user**: "Want me to also post these findings to PR #N?
(submit / request changes / skip)"

If the user says "skip", stop here. The HTML report is the
deliverable.

If the user wants to post:

#### Step 7.1: Compute diff positions

For each finding, compute the GitHub/GitLab `position` value.

**GitHub position rules:**
- The `position` is the 1-based line index in the file's entire
  unified diff, starting at 1 for the very first `@@` header
- Count every line sequentially across ALL hunks, including
  subsequent `@@` headers, context lines (` `), additions (`+`),
  and deletions (`-`)
- The count does NOT reset between hunks

If a finding's line falls outside any diff hunk, use the nearest
hunk's last position and prepend: "*Note: This issue is in unchanged
code near the diff context.*"

If position computation fails, skip the inline comment and include
the finding in the review body instead.

**GitLab:** Uses `new_line` / `old_line` in the discussions API
instead of `position`. Compute these from the diff hunk headers.

#### Step 7.2: Format comment bodies

**For `bug`/`security` findings WITH a confirmed reproducer:**

```markdown
**Bug: {title}**

{body}

Fix: {suggestion}

<details>
<summary>Reproducer</summary>

**Steps:**
{steps}

**Expected:**
{expected}

**Actual:**
{actual}

**Files:**

`{path}`:
```{lang}
{content}
```

</details>
```

**For findings where the reproducer FAILED:**

```markdown
**Potential Bug: {title}**

{body}

Note: A reproducer was attempted but did not confirm this bug.
Manual verification recommended.

Fix: {suggestion}
```

**For `style`/`architecture`/`info` findings:**

```markdown
**{Severity}: {title}**

{body}

Suggestion: {suggestion}
```

#### Step 7.3: Create PENDING review

**GitHub:**

Write the review payload to a temp file. The review body is the
verdict (same content as the HTML report's header section).

**CRITICAL**: Do NOT include an `"event"` field in the JSON.
Omitting it creates a PENDING review. Using `"event": "COMMENT"`
submits immediately.

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews \
  --method POST \
  --input /tmp/deep-review-payload.json
```

Cap at **30 inline comments**. Overflow goes to the review body.

If the API returns a 422 (usually a bad `position`), remove the
offending comment and retry.

**GitLab:** Use the discussions API to create draft notes.

#### Step 7.4: User approval gate

```
PENDING review created with N inline comments on PR #NNN.

Commands:
  "submit"           — post as informational comment
  "request changes"  — post requesting changes
  "drop"             — delete the pending review
  "edit"             — open the PR to edit comments first
```

**Do NOT submit automatically. Wait for the user.**

On "submit":
```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID/events \
  --method POST -f event="COMMENT"
```

On "request changes":
```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID/events \
  --method POST -f event="REQUEST_CHANGES"
```

On "drop":
```bash
gh api -X DELETE repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID
```

## Error Handling

- **`gh`/`glab` not authenticated**: Only matters for PR posting.
  The review itself works without authentication.
- **No PR exists**: Fine — skip Phase 7, the HTML report is the
  deliverable.
- **`codex` not installed**: Skip the codex reviewer, warn, continue.
- **Subagent timeout**: Report which reviewer timed out, continue
  with available results.
- **Empty diff**: Stop — "No changes found."
- **Position computation failure**: Move finding to review body.
- **Review creation fails (422)**: Remove bad comments, retry.

## Guardrails

- Never submit a PR review without explicit user confirmation.
- Never use `"event"` in the initial review creation payload.
- Reproducers run locally in /tmp. Do not push reproducer files
  or modify the working tree (except `deep-review.html`).
- Do not run destructive operations in reproducers. Mark as
  `not_reproducible` instead.
- Cap at 30 inline PR comments. Overflow goes to the review body.
  The HTML report has no such cap.
