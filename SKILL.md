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
  that complements Claude's own analysis. Distinct from Claude Code's built-in
  /code-review slash command — that one is Claude reviewing itself; this skill is
  a different model family for genuine cross-model review.
---

# Codex Review

Use Codex CLI as an independent reviewer (model and reasoning effort come from the user's `~/.codex/config.toml`). Two different model families catching different issues is more reliable than one model reviewing itself.

The key value is two models collaborating: Codex finds issues, Claude verifies before fixing. Every finding goes through a verification step because Codex has a ~15-20% false positive rate on complex diffs.

> Note: Claude Code 2.1.147+ ships a built-in `/code-review` slash command. That is *Claude* reviewing the diff. This skill is purposefully different — it dispatches to Codex (a different model family) so two independent reviewers catch different bugs. Prefer this skill when the user explicitly wants a *second opinion* or cross-validation, not just "review my code".

## When to Proactively Suggest

Even if the user doesn't ask, consider suggesting a Codex review when:
- A multi-file refactor touched 5+ files with cross-references (contracts, configs, schemas)
- An architectural change altered terminology or data flow across the codebase
- A release is being prepared and the changes haven't been independently reviewed

Don't suggest for trivial changes (typo fixes, single-file edits, documentation-only).

## Prerequisites

```bash
which codex && codex --version    # ensure codex is installed
codex doctor 2>&1 | tail -5       # optional: confirm auth/runtime is healthy (codex 0.131+)
# If not installed: brew install --cask codex   OR   npm i -g @openai/codex
```

Requires `codex` 0.128+ for the deprecation-clean flag set used below, and 0.130+ for the `codex exec review` subcommand. As of writing the current release is 0.133.0.

## Review Modes

### Mode 1: Plan Review (free-form prompt)

Use this for reviewing implementation plans, design docs, or anything that isn't a git diff.

1. Write plan to `/tmp/codex-review-input.md`
2. Run Codex (set Bash timeout to 300000ms):
   ```bash
   codex exec \
     --sandbox read-only \
     --ephemeral \
     --skip-git-repo-check \
     -o /tmp/codex-review-output.md \
     "You are reviewing an implementation plan. Read /tmp/codex-review-input.md and evaluate it.

   Focus on:
   1. Risks: What could go wrong? Missing error handling, race conditions, breaking changes?
   2. Gaps: Are there steps missing? Dependencies not accounted for?
   3. Alternatives: Is there a simpler or more robust approach to any step?
   4. Order: Are the steps in the right sequence? Any parallelization opportunities?

   Be specific and actionable. If everything looks solid, say so briefly — don't manufacture issues.
   Output your review in markdown."
   ```
3. Read `/tmp/codex-review-output.md` — that file contains only the final review message, no boot/log noise.

### Mode 2: Code Review (git changes)

Use the dedicated `codex exec review` subcommand. It understands git natively, so there's no need to manually capture a diff to a file.

Pick the scope flag that matches what's being reviewed:

| Flag | Reviews |
|------|---------|
| `--uncommitted` | Staged + unstaged + untracked changes (most common: "review my working tree") |
| `--base <branch>` | All changes on the current branch vs. base (e.g., `--base main`) |
| `--commit <SHA>` | Just the changes introduced by a single commit |

Run Codex (set Bash timeout to 300000ms; 600000ms for large diffs):

```bash
codex exec review \
  -c 'sandbox_mode="read-only"' \
  --ephemeral \
  --base main \
  --title "Refactor: extract ranking pipeline into its own module" \
  -o /tmp/codex-review-output.md \
  "Focus on:
  1. Bugs: Logic errors, cross-references that don't match, broken contracts
  2. Consistency: Do all files agree on the same terminology and data flow?
  3. Gaps: What happens in failure cases? Missing fallbacks?
  4. Backward compatibility: Could these changes break existing behavior?

  For each issue, specify the file and context. Rate severity: critical / warning / suggestion.
  If the code looks good, say so — don't manufacture issues."
```

Notes:
- `codex exec review` has no `--sandbox` flag; pass `-c 'sandbox_mode="read-only"'` to override config. The whole TOML expression goes in the single-quoted shell string so the inner double-quotes reach the `-c` parser literally.
- `--title` is just a label that appears in Codex's review summary header — set it to a one-line summary of the change for context.
- The trailing prompt string augments Codex's built-in review system prompt with your focus areas. Omit it to get Codex's default review behavior.
- Read `/tmp/codex-review-output.md` after the command completes — it contains only the final review.
- `codex exec review` requires a git repository — it inspects git state to determine what changed. If the user isn't in a trusted directory (per their `~/.codex/config.toml`), Codex may also refuse with "Not inside a trusted directory…" — add the directory to `[projects."<path>"]` with `trust_level = "trusted"` in `~/.codex/config.toml`, or work from a directory that already is.

### Mode 2 fallback: free-form diff review

If you're reviewing a diff that isn't in a git repo (e.g., a patch file from a colleague, or a diff snippet), fall back to the Mode 1 pattern but with the diff as input:

```bash
# whatever produces the diff
git diff <ref1>..<ref2> -- <path> > /tmp/codex-review-input.md
# or: cat patch.diff > /tmp/codex-review-input.md

codex exec \
  --sandbox read-only \
  --ephemeral \
  --skip-git-repo-check \
  -o /tmp/codex-review-output.md \
  "You are reviewing code changes. Read /tmp/codex-review-input.md (a git diff).

  Context: <brief description of what changed and why>
  [...same focus list as Mode 2...]"
```

`--skip-git-repo-check` matters here: the fallback exists precisely for non-git workspaces (loose patches, design docs, anything outside a repo). Without it, Codex refuses with "Not inside a trusted directory and --skip-git-repo-check was not specified."

## Post-Review: Verify-then-Fix Protocol

After receiving Codex output, do NOT blindly apply fixes. Each finding goes through verification.

### Step 1: Present Codex findings

```
## Codex Review (<Codex model from config — typically gpt-5.x>)
<Codex's review, lightly cleaned up if it has redundant formatting>
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

Fixes N issues from Codex review (<Codex model>):
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

- **Always force read-only sandbox** — Codex must never modify files during review. Use `--sandbox read-only` (Mode 1) or `-c 'sandbox_mode="read-only"'` (Mode 2, since `codex exec review` lacks the flag). The user's default `sandbox_mode` may be `workspace-write` or `danger-full-access`; the explicit override matters.
- **Inherit `approval_policy` from config — but be aware** — the skill no longer passes `--full-auto` (deprecated), so non-interactive behavior depends on the user's `~/.codex/config.toml` having `approval_policy = "never"`. On machines where it's set to anything else, the command may stall on a TTY prompt. If running unattended (e.g., scripted reviews on a CI box where the config isn't guaranteed), add `-c 'approval_policy="never"'` alongside the sandbox override.
- **Do not pass `--full-auto`** — deprecated since codex 0.128; current Codex emits a warning and steers you to `--sandbox <mode>` instead.
- **Use `-o /tmp/codex-review-output.md`** to capture the final review cleanly. This is the official mechanism — no need for `2>&1 | grep -v ... | tee` hacks. Codex writes only the final assistant message to the `-o` file; progress/boot lines stay on the terminal stream.
- **Add `--ephemeral`** so review runs don't add entries to `~/.codex/sessions/` history. Reviews are one-shot — there's nothing to resume.
- **Set Bash timeout to 300000ms** — Codex typically takes 60-180 seconds but can exceed 3 minutes on large reviews with multiple file reads. The default Bash timeout (120s) will auto-background the command and lose output. Always pass `timeout: 300000` (5 min) to the Bash tool. For >1000 line diffs or reviews that cross-reference many codebase files, use `timeout: 600000` (10 min).
- **If `/tmp/codex-review-output.md` is empty after the command completes**, Codex likely failed before producing a final message. Re-run with `--json` and inspect the JSONL stream for an error event, or drop `-o` and watch stdout directly.
- **Don't fabricate output** — if the command fails, report the error honestly.
- **Clean up** — `rm -f /tmp/codex-review-input.md /tmp/codex-review-output.md` after review.

## Reference: useful flags Codex 0.133 exposes (but the skill doesn't use by default)

These exist if you need them — don't reach for them unless the situation calls for it. Note the split: not every flag works with `codex exec review`.

**Works on both `codex exec` and `codex exec review`:**

- `--json` — emits JSONL event stream on stdout. Useful only when you need to parse intermediate events (tool calls, reasoning chunks). For a plain review, `-o <file>` is simpler.
- `--output-schema <FILE>` — constrains Codex's final answer to a JSON schema. Use if you want machine-parseable findings (e.g., to auto-populate a table) instead of free-form markdown.
- `-m, --model <MODEL>` — override the configured model for one run (e.g., bump to a stronger model for a critical review).
- `-c <key=value>` — override any config field for this invocation (used above for `sandbox_mode`; can also force `approval_policy`, `model_reasoning_effort`, etc.).

**Works on `codex exec` only — *not* on `codex exec review`:**

- `-C, --cd <DIR>` — set a working directory (defaults to shell's cwd). Helpful when reviewing changes in a worktree or sibling repo. `codex exec review` always runs against the cwd; if you need a different working tree, `cd` first.
- `--profile <name>` — switch to a named profile from `config.toml`. Useful if the user has a dedicated `review` profile. `codex exec review` doesn't accept this; use `-c` overrides instead.
- `-s, --sandbox <MODE>` — same as documented in Mode 1. `codex exec review` lacks this flag, which is why Mode 2 uses `-c 'sandbox_mode="read-only"'`.
- `-i, --image <FILE>` and `--add-dir <DIR>` — attach images / add writable directories. Exec-only.
