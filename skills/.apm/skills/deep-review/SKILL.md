---
name: "deep-review"
description: "Multi-agent panel code review with forced runtime reproducers for all bug findings. Checks out the PR locally, dispatches parallel reviewers, verifies bugs, and creates a PENDING review with inline comments — won't submit until you approve."
argument-hint: "[-supply-chain,-codex,...] [pr-url]"
---

# Deep Review — Multi-Agent Panel Review with Reproducers

Check out a PR locally, understand the changes, dispatch parallel
subagent reviewers (each with a different focus), verify every bug
with a runtime reproducer, then post results as a GitHub/GitLab
PENDING review with inline comments. Nothing is submitted until the
user approves.

## Arguments

```
/deep-review [modifiers] [pr-url]
```

All reviewer types are enabled by default. Use `-` prefix to exclude:

| Argument | Description |
|----------|-------------|
| modifiers | Comma-separated. Prefix with `-` to exclude a default reviewer (e.g., `-supply-chain,-codex`). Bare names are no-ops since all are already enabled |
| pr-url | GitHub or GitLab PR/MR URL. Omit to infer from current branch |

Examples:

- `/deep-review` — all reviewers, infer PR from current branch
- `/deep-review -codex` — skip the codex CLI reviewer
- `/deep-review -supply-chain,-architecture https://github.com/org/repo/pull/42`
- `/deep-review https://gitlab.com/org/repo/-/merge_requests/7` — GitLab MR

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
  is the PR/MR URL
- All reviewers are enabled by default; only `-` prefixed names
  remove them

#### Step 1.2: Determine the PR and platform

Detect the platform (GitHub or GitLab) from the URL or the current
repo's remote.

**GitHub:**
```bash
gh pr view --json number,url,baseRefName,headRefName,title
```

**GitLab:**
```bash
glab mr view --output json
```

If this fails, stop: "No PR/MR found for the current branch. Push
and open one first, or pass a URL."

Extract: `OWNER`, `REPO`, `PR_NUMBER`, `BASE_REF`, `HEAD_REF`,
`PR_TITLE`.

#### Step 1.3: Check out the PR locally

If not already on the PR's branch, check it out:

**GitHub:**
```bash
gh pr checkout $PR_NUMBER
```

**GitLab:**
```bash
glab mr checkout $PR_NUMBER
```

#### Step 1.4: Ensure the merge base is up-to-date

Fetch the base branch and compute the merge base:

```bash
git fetch origin $BASE_REF
MERGE_BASE=$(git merge-base origin/$BASE_REF HEAD)
```

This merge base is used for all diffs throughout the review. Tell
all subagents to diff against this ref.

#### Step 1.5: Get the diff and changed files

```bash
git diff $MERGE_BASE...HEAD > /tmp/deep-review-diff.patch
git diff $MERGE_BASE...HEAD --name-only
```

Also fetch the PR/MR description for context:

**GitHub:**
```bash
gh pr view $PR_NUMBER --json body --jq '.body'
```

**GitLab:**
```bash
glab mr view $PR_NUMBER --output json | jq -r '.description'
```

If the diff is empty, stop: "PR has no changes to review."

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
on this same PR, skip this phase entirely.**

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

Before creating the review, act as an arbiter over all reviewer
outputs. Review every finding from every reviewer and decide what
to include in the final review.

#### Step 5.1: Deduplicate

Multiple reviewers may find the same issue. Merge duplicates,
keeping the most detailed description and the strongest reproducer.

#### Step 5.2: Filter noise

Remove findings that are:
- Clearly false positives (contradicted by code the reviewer missed)
- Style nitpicks that don't match the project's conventions
- Speculative ("this could be a problem if...") without evidence
- Already addressed elsewhere in the PR (e.g., in a later commit)

#### Step 5.3: Prioritize

Rank remaining findings by severity and impact:
1. Reproduced bugs with security implications
2. Reproduced functional bugs
3. Unreproduced but plausible bugs (downgraded to `potential`)
4. Architecture/design concerns
5. Style and quality notes

#### Step 5.4: Present arbiter summary

Show the user the curated findings before creating the review:

```
Arbiter summary: N findings from M reviewers.
Kept: X bugs (Y reproduced), Z style/arch notes.
Dropped: W duplicates, V false positives.
```

Proceed to Phase 6 unless the user objects.

### Phase 6 — Create PENDING Review

#### Step 6.1: Compute diff positions

For each finding, compute the GitHub/GitLab `position` value.

**GitHub position rules:**
- The `position` is the 1-based line index in the file's entire
  unified diff, starting at 1 for the very first `@@` header
- Count every line sequentially across ALL hunks, including
  subsequent `@@` headers, context lines (` `), additions (`+`),
  and deletions (`-`)
- The count does NOT reset between hunks

Generate the diff for position mapping:

```bash
git diff $MERGE_BASE...HEAD -- $FILE
```

If a finding's line falls outside any diff hunk, use the nearest
hunk's last position and prepend: "*Note: This issue is in unchanged
code near the diff context.*"

If position computation fails, skip the inline comment and include
the finding in the review body instead.

**GitLab:** Uses `new_line` / `old_line` in the discussions API
instead of `position`. Compute these from the diff hunk headers.

#### Step 6.2: Format comment bodies

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

#### Step 6.3: Build review payload

**GitHub:**

Write to a temp file:

```bash
cat > /tmp/deep-review-payload.json << 'EOF'
{
  "body": "<summary table>",
  "comments": [
    {"path": "file.py", "position": 10, "body": "**Bug: ...**"}
  ]
}
EOF
```

The review body should contain a summary table:

```markdown
## Deep Review Summary

| Severity | Count | Reproduced |
|----------|-------|------------|
| Bug      | N     | M/N        |
| Security | N     | M/N        |
| Potential | N    | —          |
| Style    | N     | —          |
| Architecture | N | —          |

Reviewers: bugs, adversarial, correctness, ...
```

Cap at **30 inline comments**. If more than 30 findings, keep the
highest-severity ones inline and list the rest in the review body.

**CRITICAL**: Do NOT include an `"event"` field in the JSON. Omitting
it creates a PENDING review. Using `"event": "COMMENT"` submits the
review immediately, which defeats the approval gate.

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews \
  --method POST \
  --input /tmp/deep-review-payload.json
```

Extract the review ID from the response (`--jq '.id'`).

If the API returns a 422 (usually a bad `position`), remove the
offending comment and retry. Move dropped comments to the review
body.

**GitLab:**

Use the discussions API to create draft notes:

```bash
glab api projects/$PROJECT_ID/merge_requests/$MR_IID/discussions \
  --method POST ...
```

#### Step 6.4: Write the verdict

After all inline comments are placed, write a verdict as the review
body. This is the arbiter's final opinion on the PR — a synthesis,
not a list.

The verdict should include:

1. **Disposition**: One of:
   - **Approve** — no bugs found, or only minor style notes
   - **Approve with nits** — minor issues that don't block merge
   - **Request changes** — reproduced bugs or significant concerns
   - **Reject** — fundamental design or security problems

2. **Summary**: 2-3 sentences on what the PR does and whether the
   approach is sound.

3. **Key findings**: The most important issues, with one-line
   summaries. Reference the inline comments ("see comment on
   `file.py:42`").

4. **What's good**: Briefly acknowledge things done well — this
   isn't just a bug hunt.

5. **Recommendation**: What the author should do next (fix N bugs
   and reship, rethink approach, good to merge as-is, etc.).

Format:

```markdown
## Deep Review Verdict

**Disposition: {Request Changes}**

{Summary of what the PR does and overall assessment.}

### Key Findings

| # | Severity | File | Finding | Reproduced? |
|---|----------|------|---------|-------------|
| 1 | Bug | `file.py:42` | Title | Yes |
| 2 | Bug | `other.py:10` | Title | Yes |
| 3 | Style | `lib.rs:88` | Title | — |

### What's Good

{Brief acknowledgement of solid work in the PR.}

### Recommendation

{What the author should do next.}

---
Reviewers: {list}
*Generated by `/deep-review`*
```

#### Step 6.5: Present results to the user

Show the user:

```
PENDING review created with N inline comments on PR #NNN.

Verdict: {disposition}

| Severity | Count | Reproduced |
|----------|-------|------------|
| Bug      | N     | M/N        |
| ...      | ...   | ...        |

Review URL: {PR_URL}

Commands:
  "submit"           — post as informational comment
  "request changes"  — post requesting changes
  "drop"             — delete the pending review
  "edit"             — open the PR in browser to edit first
```

### Phase 7 — User Approval Gate

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

On "edit":

Tell the user to visit the PR URL, edit/delete individual comments
in the GitHub/GitLab UI, then come back and say "submit" or "drop".

## Error Handling

- **`gh`/`glab` not authenticated**: Stop — "Run `gh auth login`
  or `glab auth login` first."
- **PR/MR not found**: Stop — show the error.
- **`codex` not installed**: Skip the codex reviewer, warn, continue.
- **Subagent timeout**: Report which reviewer timed out, continue
  with available results.
- **Empty diff**: Stop — "PR has no changes to review."
- **Position computation failure**: Move finding to review body.
- **Review creation fails (422)**: Remove bad comments, retry.
  Show raw payload on persistent failure.

## Guardrails

- Never submit a review without explicit user confirmation.
- Never use `"event"` in the initial review creation payload.
- Reproducers run locally. Do not push reproducer files or modify
  the working tree permanently. Use /tmp for all reproducer files.
- Do not run destructive operations in reproducers (dropping
  databases, deleting non-temp files). Mark as `not_reproducible`.
- Cap at 30 inline comments per review. Overflow goes to the
  review body.
