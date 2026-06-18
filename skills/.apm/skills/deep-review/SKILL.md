---
name: "deep-review"
description: "Multi-agent panel code review with forced runtime reproducers for all bug findings. Creates a GitHub PENDING review with inline comments — won't submit until you approve."
argument-hint: "[bugs,adversarial,codex,...] [pr-url]"
---

# Deep Review — Multi-Agent Panel Review with Reproducers

Dispatch parallel subagent reviewers, each with a different focus.
Every bug finding is verified with a runtime reproducer before
posting. Results become a GitHub PENDING review with inline comments
and collapsible reproducer details. Nothing is submitted until the
user approves.

## Arguments

```
/deep-review [reviewers] [pr-url]
```

| Argument | Default | Description |
|----------|---------|-------------|
| reviewers | `bugs,adversarial` | Comma-separated reviewer types |
| pr-url | (inferred) | GitHub PR URL. Omit to infer from current branch |

Examples:

- `/deep-review` — default reviewers, infer PR
- `/deep-review bugs,codex` — bugs + external codex review
- `/deep-review bugs,adversarial,supply-chain https://github.com/org/repo/pull/42`
- `/deep-review correctness,architecture` — spec compliance + design review

## Reviewer Types

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

Parse the argument string. The first token that looks like a
comma-separated word list (no slashes, no dots) is the reviewer
list. The first token containing `github.com` and `/pull/` is the
PR URL. Either or both may be absent.

Default reviewers when none specified: `bugs,adversarial`.

#### Step 1.2: Determine the PR

If a PR URL was provided, extract `OWNER`, `REPO`, and `PR_NUMBER`.

If no URL, infer from the current branch:

```bash
gh pr view --json number,url,baseRefName,headRefName,title
```

If this fails, stop: "No PR found for the current branch. Push and
open a PR first, or pass a PR URL."

#### Step 1.3: Fetch diff and context

Run in parallel:

```bash
gh pr diff $PR_NUMBER --repo $OWNER/$REPO > /tmp/deep-review-diff.patch
gh pr diff $PR_NUMBER --repo $OWNER/$REPO --name-only
gh pr view $PR_NUMBER --repo $OWNER/$REPO --json body --jq '.body'
```

If the diff is empty, stop: "PR has no changes to review."

### Phase 2 — Dispatch Reviewers

Launch one subagent per selected reviewer type, **all in parallel**,
using the Agent tool with `run_in_background: true`.

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

Each reviewer subagent gets the full diff, changed file list, and
access to the codebase. Use these prompts:

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
> **Method**: Read the full diff. For each changed file, read the
> FULL file (not just the diff) to understand context. Trace code
> paths — follow function calls, check callers and callees, check
> base class methods that are inherited but not overridden. For
> each bug found, set `reproducer_needed: true`.

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
> Set `reproducer_needed: true` for every finding.

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
> For findings that claim a concrete bug, set `reproducer_needed:
> true`. For spec/contract mismatches, set severity to `potential`.

---

**supply-chain** reviewer:

> You are a supply-chain security reviewer.
>
> **Your focus**: New dependencies — check names for typosquatting.
> Lockfile changes — unexpected version bumps, new transitive deps.
> Build script modifications — download URLs, curl|bash, post-install
> scripts. Container image changes — unverified registries, tag
> mutability. GitHub Actions changes — new third-party actions,
> version unpinning. Credential exposure — API keys, tokens in code.
>
> Set `reproducer_needed: false` for all findings. Set severity to
> `security` for confirmed risks.

---

**codex** reviewer:

This reviewer does NOT use a subagent prompt. Run the CLI directly:

```bash
gh pr diff $PR_NUMBER --repo $OWNER/$REPO | codex review -
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
> For findings claiming a concrete bug or regression, set
> `reproducer_needed: true`. For quality issues, set severity
> to `style`.

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
> Set severity to `architecture` for all findings. Set
> `reproducer_needed: false`. Focus on decisions costly to change.

### Phase 3 — Reproduce

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

### Phase 4 — Create PENDING Review

#### Step 4.1: Compute diff positions

For each finding, compute the GitHub `position` value. This is the
line number within the **diff hunk**, NOT the file line number.

Rules:
1. Parse the diff for the target file
2. Find the `@@ -a,b +c,d @@` hunk containing the target line
3. Count every line after the `@@` header, starting at 1
4. Context (` `), additions (`+`), and deletions (`-`) all count
5. For entirely new files, position = line number in the new file

If a finding's line falls outside any diff hunk, use the nearest
hunk's last position and prepend: "*Note: This issue is in unchanged
code near the diff context.*"

If position computation fails, skip the inline comment and include
the finding in the review body instead.

#### Step 4.2: Format comment bodies

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

#### Step 4.3: Build review payload

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

Reviewers: bugs, adversarial
```

Cap at **30 inline comments**. If more than 30 findings, keep the
highest-severity ones inline and list the rest in the review body.

#### Step 4.4: Submit PENDING review

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews \
  --method POST \
  --input /tmp/deep-review-payload.json
```

**CRITICAL**: Do NOT include an `"event"` field in the JSON. Omitting
it creates a PENDING review. Using `"event": "COMMENT"` submits the
review immediately, which defeats the approval gate.

Extract the review ID from the response:

```bash
REVIEW_ID=$(... --jq '.id')
```

If the API returns a 422 (usually a bad `position`), remove the
offending comment and retry. Move dropped comments to the review
body.

### Phase 5 — User Approval Gate

Present results to the user:

```
PENDING review created with N inline comments on PR #NNN.

| Severity | Count | Reproduced |
|----------|-------|------------|
| Bug      | N     | M/N        |
| ...      | ...   | ...        |

Review URL: {PR_URL}

Commands:
  "submit"         — post as informational comment
  "request changes" — post requesting changes
  "drop"           — delete the pending review
  "edit"           — open the PR in browser to edit first
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

- **`gh` not authenticated**: Stop — "Run `gh auth login` first."
- **PR not found**: Stop — show the error.
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
