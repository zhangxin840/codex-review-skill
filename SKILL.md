---
name: codex-review
description: >
  Use OpenAI Codex CLI as a second-opinion reviewer for plans and code changes.
  Triggers when the user asks for Codex review, cross-validation, second opinion,
  or explicitly mentions "codex". Also use when the user says things like
  "用 codex 审一下", "交叉验证", "第二意见", "让 codex 看看", "codex review",
  "double check with codex", "get another perspective", or after completing a plan
  when the user wants validation before proceeding. This skill runs codex exec
  in read-only mode using the model and reasoning effort configured in the user's
  ~/.codex/config.toml, providing an independent review from a different AI model
  that complements Claude's own analysis.
---

# Codex Review

Use Codex CLI as an independent reviewer (model and reasoning effort come from the user's `~/.codex/config.toml`). Two different model families catching different issues is more reliable than one model reviewing itself.

The key value is two models collaborating: Codex finds issues, Claude verifies before fixing. Every finding goes through a verification step because Codex has a ~15-20% false positive rate on complex diffs.

## When to Proactively Suggest

Even if the user doesn't ask, consider suggesting a Codex review when:
- A multi-file refactor touched 5+ files with cross-references (contracts, configs, schemas)
- An architectural change altered terminology or data flow across the codebase
- A release is being prepared and the changes haven't been independently reviewed

Don't suggest for trivial changes (typo fixes, single-file edits, documentation-only).

## Prerequisites

```bash
which codex && codex --version
# If not installed: npm i -g @openai/codex
```

## Review Modes

### Mode 1: Plan Review

1. Write plan to `/tmp/codex-review-input.md`
2. Run Codex (set Bash timeout to 300000ms):
   ```bash
   codex exec \
     --sandbox read-only \
     --full-auto \
     "You are reviewing an implementation plan. Read /tmp/codex-review-input.md and evaluate it.

   Focus on:
   1. Risks: What could go wrong? Missing error handling, race conditions, breaking changes?
   2. Gaps: Are there steps missing? Dependencies not accounted for?
   3. Alternatives: Is there a simpler or more robust approach to any step?
   4. Order: Are the steps in the right sequence? Any parallelization opportunities?

   Be specific and actionable. If everything looks solid, say so briefly — don't manufacture issues.
   Output your review in markdown." \
     2>&1 | grep -v '^\(Reading\|OpenAI Codex\|--------\|workdir:\|model:\|provider:\|approval:\|sandbox:\|reasoning\|session id:\|user\|codex\|exec\| succeeded\)' \
     | tee /tmp/codex-review-output.md
   ```

### Mode 2: Code Review

1. Capture diff: `git diff <ref1>..<ref2> -- <path> > /tmp/codex-review-input.md`
2. Add context in the prompt (what changed, why, key files)
3. Run Codex (set Bash timeout to 300000ms):
   ```bash
   codex exec \
     --sandbox read-only \
     --full-auto \
     "You are reviewing code changes. Read /tmp/codex-review-input.md (a git diff).

   Context: <brief description of what changed and why>

   Focus on:
   1. Bugs: Logic errors, cross-references that don't match, broken contracts
   2. Consistency: Do all files agree on the same terminology and data flow?
   3. Gaps: What happens in failure cases? Missing fallbacks?
   4. Backward compatibility: Could these changes break existing behavior?

   For each issue, specify the file and context. Rate severity: critical / warning / suggestion.
   If the code looks good, say so — don't manufacture issues.
   Output your review in markdown." \
     2>&1 | grep -v '^\(Reading\|OpenAI Codex\|--------\|workdir:\|model:\|provider:\|approval:\|sandbox:\|reasoning\|session id:\|user\|codex\|exec\| succeeded\)' \
     | tee /tmp/codex-review-output.md
   ```

## Post-Review: Verify-then-Fix Protocol

After receiving Codex output, do NOT blindly apply fixes. Each finding goes through verification.

### Step 1: Present Codex findings

```
## Codex Review (GPT-5.5)
<Codex's review, cleaned up>
---
*Reviewed by Codex CLI in read-only sandbox mode*
```

### Step 2: Verify each finding

For every finding Codex reports, Claude checks the actual files:

```
For each finding:
  1. Read the specific file and line Codex references
  2. Check if the issue actually exists (Codex may misread diffs)
  3. If Codex claims File A contradicts File B — read both files and confirm
  4. Classify:
     - CONFIRMED: issue exists, needs fix
     - PARTIALLY VALID: real issue but severity/scope differs
     - FALSE POSITIVE: Codex misread the code or context
     - NOTED: valid observation but acceptable trade-off
```

Present as a verification table:

| # | Codex Finding | Severity | Claude Verdict | Action |
|---|--------------|----------|---------------|--------|
| 1 | description... | critical | **Confirmed** | Fix: ... |
| 2 | description... | warning | **False positive** | No action (reason) |

### Step 3: Fix only confirmed issues

Apply fixes for CONFIRMED and PARTIALLY VALID findings. Skip FALSE POSITIVE. Document NOTED items in commit message.

### Step 4: Commit with audit trail

Include Codex review results in commit message so the review history is preserved:

```
fix: address Codex review findings — <summary>

Fixes N issues from Codex review (GPT-5.5):
1. [severity] description — fix applied
2. [severity] description — fix applied

Not fixed (acceptable):
- description — reason

Co-Authored-By: Claude <noreply@anthropic.com>
```

## Why Verification Matters

- **Codex's strength**: Cross-file consistency — it catches when File A says X but File B says Y (e.g., a config says "hard gate" but the code treats it as soft, or an API contract defines one output path but the caller writes to another).

- **Codex's weakness**: It can over-report on large diffs, conflate design choices with bugs, or miss context that explains why something is intentional. Architectural judgment calls are unreliable.

- **False positive rate**: ~15-20% in practice. Without verification, you risk fixing non-issues and introducing new bugs.

## Important Constraints

- **Always use `--sandbox read-only`** — Codex should never modify files
- **Always use `--full-auto`** — avoid interactive prompts that hang
- **Merge stderr into stdout** (`2>&1`) — Codex writes progress/boot info to stderr; merging ensures output is captured even if the Bash tool auto-backgrounds the command. Pipe through `grep -v` to strip Codex boot lines, then `tee /tmp/codex-review-output.md` to both display and persist the review output
- **Set Bash timeout to 300000ms** — Codex typically takes 60-180 seconds but can exceed 3 minutes on large reviews with multiple file reads. The default Bash timeout (120s) will auto-background the command and lose output. Always pass `timeout: 300000` (5 min) to the Bash tool. For >1000 line diffs or reviews that cross-reference many codebase files, use `timeout: 600000` (10 min)
- **If output is empty**, read `/tmp/codex-review-output.md` — the `tee` fallback ensures output is saved even when Bash truncates or backgrounds
- **Don't fabricate output** — if the command fails, report the error honestly
- **Clean up** — `rm -f /tmp/codex-review-input.md /tmp/codex-review-output.md` after review
