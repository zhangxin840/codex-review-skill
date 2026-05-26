---
name: codex-review
description: >
  Use OpenAI Codex CLI as an independent second-opinion reviewer for
  implementation plans, git diffs, PR or branch changes, and failing-test
  root-cause patches. Runs Codex read-only and requires Claude to verify each
  finding before fixing.
when_to_use: >
  Trigger when the user asks for Codex review, cross-validation, a second
  opinion, external review before delivery, or phrases like "用 codex 审一下",
  "交叉验证", "第二意见", "让 codex 看看", "codex review", "double check with
  codex", "review with Codex", or "get another perspective". Do not trigger for
  general Codex setup/config/news/model questions, or when the user says not to
  run Codex.
argument-hint: "[plan|code|git-uncommitted|git-base <branch>|git-commit <sha>]"
---

# Codex Review

Use Codex CLI as an independent reviewer (model and reasoning effort come from
the user's `~/.codex/config.toml`). Two different model families catching
different issues is more reliable than one model reviewing itself.

The key value is two models collaborating: Codex finds issues, Claude verifies
before fixing. Every finding goes through a verification step because Codex
has a ~15-20% false positive rate on complex diffs.

> Note: Claude Code includes a bundled `/code-review` skill, and user/project
> commands can add review prompts such as `/review`. Those are *Claude*
> reviewing the diff. This skill is different: it dispatches to Codex (a
> different model family). Prefer it when the user explicitly wants a *second
> opinion* or cross-validation, not just "review my code".

## When to Proactively Suggest

Even if the user doesn't ask, consider suggesting a Codex review when:
- A multi-file refactor touched 5+ files with cross-references (contracts,
  configs, schemas)
- An architectural change altered terminology or data flow across the codebase
- A release is being prepared and the changes haven't been independently reviewed

Don't suggest for trivial changes (typo fixes, single-file edits,
documentation-only).

## Prerequisites

```bash
which codex && codex --version    # ensure codex is installed (need 0.130+)
codex doctor 2>&1 | tail -5       # confirm auth/runtime health (codex 0.131+)
# If not installed: brew install --cask codex   OR   npm i -g @openai/codex
```

Tested against **Claude Code 2.1.150** and **codex-cli 0.133.0** (both
current on npm as of 2026-05-26). All flags below were verified against
`codex exec review --help` and `codex exec --help` on this version. Official
OpenAI docs describe `codex exec` as the scripted / CI-style non-interactive
entrypoint; official Claude Code docs describe skills as `SKILL.md` files under
`~/.claude/skills/<skill-name>/` that can be invoked directly with
`/skill-name`.

## Preferred Helper

Prefer the bundled helper script when running this skill. It centralizes the
current Codex flags, timeout wrapper, stale-output cleanup, and custom diff
capture logic:

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" --help
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-uncommitted
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-base main
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-base-custom main
```

Use the manual commands below only when you need to adapt a one-off review or
debug the helper. The helper echoes Codex's final review to stdout and writes
the same final message to `${CODEX_REVIEW_OUTPUT:-/tmp/codex-review-output.md}`.

## ⚠️ Hard Rule: Always Wrap Codex with a Timeout

**Codex has been observed to hang silently for 30-40+ minutes** on some
prompts (suspected triggers: Unicode math symbols like σ²/β/X'X in the
prompt text, transient OpenAI API stalls, very long prompts >2000 chars).
The Bash tool's `timeout` parameter only bounds the Bash call — if the
codex process is backgrounded or the parent shell waits on the output
file, codex itself keeps running.

**Always invoke codex through a kill-on-timeout wrapper** so the child
process gets killed regardless of how the Bash call is structured.

### Portable timeout wrapper (works on macOS + Linux)

GNU `timeout` is preinstalled on Linux but **NOT on macOS** (you'd need
`brew install coreutils`, which gives you `gtimeout`). Use this auto-fallback:

```bash
# Pick the first available: gtimeout (mac with coreutils), timeout (linux),
# else a shell-based process-tree watchdog (always available).
kill_tree() {
  local pid="$1"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null || true
}

codex_with_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5s "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout -k 5s "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill -0 "$pid" 2>/dev/null && kill_tree "$pid" ) &
    local watchdog=$!
    wait "$pid"
    local rc=$?
    kill "$watchdog" 2>/dev/null
    return $rc
  fi
}

# Use it:
codex_with_timeout 600 codex exec --sandbox read-only \
  -c 'approval_policy="never"' --ephemeral --skip-git-repo-check \
  -o /tmp/codex-review-output.md "your prompt"
```

If the wrapper kills codex (timeout fires), the output file will be
0 bytes or partial. **Treat that as a failure signal and report it
honestly** — do NOT poll the output file indefinitely (this skill's
previous version had a poll loop that hung the calling agent for tens
of minutes).

Recovery if codex DID hang earlier in the session:

```bash
pgrep -af "codex exec" | head
# kill the codex *binary* PIDs (deepest child) AND the wrapping node/zsh PIDs
pkill -9 -f "codex exec" 2>/dev/null
```

## Review Modes

### Mode 1: Plan Review (free-form prompt)

Use this for reviewing implementation plans, design docs, or anything that
isn't a git diff. Also use this when you need a **custom prompt against a
specific diff scope** — `codex exec review` doesn't accept a custom prompt
together with a scope flag (see Mode 2 caveat).

1. Write content to `/tmp/codex-review-input.md` (the input file).
2. Prefer the helper:

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" plan /tmp/codex-review-input.md
```

3. Manual equivalent if debugging the helper:

```bash
# Using the codex_with_timeout shell function defined above
codex_with_timeout 600 codex exec \
  --sandbox read-only \
  -c 'approval_policy="never"' \
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

4. Verify the output file actually has content:

```bash
ls -la /tmp/codex-review-output.md
test -s /tmp/codex-review-output.md && cat /tmp/codex-review-output.md \
  || echo "ERROR: codex output empty — likely timed out or hit an API error"
```

### Mode 2: Code Review (git changes, no custom prompt)

When you trust Codex's default review prompt and just want it pointed at a
specific scope of changes, use the dedicated `codex exec review` subcommand
**without** a custom prompt argument. Pick exactly one scope flag:

| Scope flag | Reviews |
|------------|---------|
| `--uncommitted` | Staged + unstaged + untracked changes |
| `--base <branch>` | All changes on the current branch vs. base |
| `--commit <SHA>` | Just the changes introduced by a single commit |

Prefer the helper:

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-uncommitted
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-base main
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-commit <SHA>
```

Manual equivalent:

```bash
codex_with_timeout 600 codex exec review \
  -c 'sandbox_mode="read-only"' \
  -c 'approval_policy="never"' \
  --ephemeral \
  --base main \
  --title "Refactor: extract ranking pipeline into its own module" \
  -o /tmp/codex-review-output.md
```

Notes:
- `--ephemeral`, `-o`, `--skip-git-repo-check`, and `--output-schema` ARE
  all available on `codex exec review` (verified against 0.133.0 help).
- `--title` is just a label that shows in Codex's review summary.
- Codex applies its built-in review prompt — focused on bugs, contracts,
  consistency, regressions — when you don't pass your own.

### Mode 2-custom: Code Review with custom focus prompt

⚠️ **`codex exec review` rejects a custom prompt together with a scope flag**:

```
error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'
```

This is by design in codex 0.133: scope flags (`--base`/`--uncommitted`/
`--commit`) and the positional `[PROMPT]` are mutually exclusive. If you
need both — a specific diff scope AND your own focus list — use the helper's
custom modes, which capture the diff and then run plain `codex exec`:

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-uncommitted-custom
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-base-custom main
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-commit-custom <SHA>
```

Manual equivalent:

```bash
# Capture the exact scope you want
git diff main..HEAD > /tmp/codex-review-input.md
# For uncommitted changes, include staged, unstaged, and untracked file content.
# The helper does this for you; don't capture only `git status`.
git diff --cached --binary > /tmp/codex-review-input.md
git diff --binary >> /tmp/codex-review-input.md
# For untracked files, append `git diff --no-index --binary -- /dev/null <file>`.
# For single commits, use: git show --binary <SHA> > /tmp/codex-review-input.md

# Then run Mode 1's `codex exec` (NOT `codex exec review`) with --skip-git-repo-check
codex_with_timeout 600 codex exec \
  --sandbox read-only \
  -c 'approval_policy="never"' \
  --ephemeral \
  --skip-git-repo-check \
  -o /tmp/codex-review-output.md \
  "Review the diff at /tmp/codex-review-input.md.

  Context: <one-sentence what changed and why>
  Scope notes: <e.g., 'binaries excluded by design', 'WIP — error paths intentional'>

  Focus on:
  1. Bugs: Logic errors, cross-references that don't match, broken contracts
  2. Consistency: Do all files agree on the same terminology and data flow?
  3. Gaps: What happens in failure cases? Missing fallbacks?
  4. Backward compatibility: Could these changes break existing behavior?

  For each finding: file:line + severity (critical/warning/suggestion).
  If solid, say so briefly. Under 700 words."
```

## Review Prompt Grounding

For custom review prompts, ground Codex in the exact scope:

- Declare exclusions up front. If the diff is text-only, path-filtered,
  staged-only, or excludes binaries, say that explicitly so Codex does not
  flag intentionally missing artifacts.
- For large diffs (>1000 lines), list suspected weak spots as concrete
  verification questions with file/line pointers. Codex is much more useful
  when asked to check specific invariants than when given only "review for
  bugs".
- Ask contract questions, not taste questions: "does `T13_COLUMNS` match the
  customer schema and e2e tests?" is useful; "is this design good?" is not.
- If Codex says a metadata/key/alias should be removed or denied, first grep
  for runtime readers before deleting it. Some "leaked" keys are load-bearing
  cross-file contracts.

## Prompt Hygiene (avoid the hang traps)

Real-world hangs observed against codex 0.133 traced to one or more of:

- **Unicode math / superscript symbols** in the prompt: `σ²`, `β`, `X'X`,
  `²`, `√`, `≤`. Suspected shell-escape or tokenizer interaction.
  → Use ASCII equivalents: `sigma2`, `beta`, `XtX`, `sqrt`, `<=`.
- **Very long single-line prompts** (>2000 chars). Multi-line via real
  newlines is fine; gigantic one-liners are not.
  → If your focus list is long, save it as a file and reference it from
  the prompt: write `/tmp/codex-focus.md` then say in the prompt
  "Read /tmp/codex-focus.md for the focus list."
- **Embedded LaTeX or backtick-heavy math notation**.
  → Same fix: ASCII or a file.
- **Multiple competing shell-escape layers** (Bash double-quote inside
  single-quote inside zsh `eval`). Codex's argv parser sometimes stalls.
  → Prefer here-doc to a temp file, then `cat`:

```bash
cat > /tmp/codex-prompt.txt <<'PROMPT_EOF'
Review the diff at /tmp/codex-review-input.md.

Focus on:
1. Bugs
2. Consistency
3. Gaps

For each finding: file:line + severity. Under 700 words.
PROMPT_EOF

codex_with_timeout 600 codex exec --sandbox read-only -c 'approval_policy="never"' \
  --ephemeral --skip-git-repo-check \
  -o /tmp/codex-review-output.md \
  "$(cat /tmp/codex-prompt.txt)"
```

## Post-Review: Verify-then-Fix Protocol

After receiving Codex output, do NOT blindly apply fixes. Each finding
goes through verification.

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
     - STALE: Codex referenced a file:line that doesn't match the current
       diff (e.g., cached prior-session output) — re-run review on the
       fresh diff before acting
```

Present as a verification table:

| # | Codex Finding | Severity | Claude Verdict | Action |
|---|--------------|----------|---------------|--------|
| 1 | description... | critical | **Confirmed** | Fix: ... |
| 2 | description... | warning | **False positive** | No action (reason) |

### Step 3: Fix only confirmed issues

Apply fixes for CONFIRMED and PARTIALLY VALID findings. Skip FALSE
POSITIVE. Document NOTED items in commit message. Re-run review on STALE
findings if they look load-bearing.

### Step 4: Commit with audit trail

Include Codex review results in commit message so the review history is
preserved:

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

- **Codex's strength**: Cross-file consistency — it catches when File A
  says X but File B says Y (e.g., a config says "hard gate" but the code
  treats it as soft, or an API contract defines one output path but the
  caller writes to another).

- **Codex's weakness**: It can over-report on large diffs, conflate design
  choices with bugs, miss context that explains why something is
  intentional, and occasionally return STALE output (the `-o` file appears
  to contain a prior session's review when codex partially fails on the
  current call). Always sanity-check the first finding's file:line against
  the actual diff before trusting the rest.

- **False positive rate**: ~15-20% in practice. Without verification, you
  risk fixing non-issues and introducing new bugs.

## Important Constraints

- **Always force read-only sandbox.** Codex must never modify files
  during review. Use `--sandbox read-only` (Mode 1) or
  `-c 'sandbox_mode="read-only"'` (Mode 2). The user's default
  `sandbox_mode` may be `workspace-write` or `danger-full-access`; the
  explicit override matters.
- **Always force `approval_policy="never"`** if running unattended. The
  skill no longer passes the deprecated `--full-auto`. On machines where
  the user's config sets `approval_policy = "on-request"` or similar, the
  command will stall on a TTY prompt forever. The `-c 'approval_policy="never"'`
  override prevents that.
- **Do not pass `--full-auto`.** Deprecated since codex 0.128; current
  Codex emits a warning and steers you to `--sandbox <mode>` instead.
- **Use `-o /tmp/codex-review-output.md`** to capture the final review
  cleanly. Codex writes only the final assistant message to the `-o`
  file; progress/boot lines stay on the terminal stream.
- **Add `--ephemeral`** so review runs don't add entries to
  `~/.codex/sessions/` history. Reviews are one-shot — nothing to resume.
- **Always wrap with the portable timeout helper** (see top of this file).
  Claude Code's Bash timeout and a parent-only `kill` are not enough when
  codex's node shim launches a native child process.
- **If `/tmp/codex-review-output.md` is empty or 0 bytes** after the
  command completes (or after `timeout` exit 124), do NOT poll-wait for
  it. Report the failure: "Codex review didn't produce output — likely
  timed out or hit an API error. Proceeding without it OR retrying with
  simplified prompt." The skill's previous version had a poll loop that
  could hang the calling agent for tens of minutes.
- **Don't fabricate output** — if the command fails, report the error
  honestly and proceed without the review.
- **Clean up** — `rm -f /tmp/codex-review-input.md /tmp/codex-prompt.txt
  /tmp/codex-review-output.md` after manual reviews. The helper removes only
  its default scratch input and preserves caller-supplied input files.

## Verified Flag Reference (codex 0.133.0)

`codex exec` (Mode 1):

| Flag | Purpose |
|------|---------|
| `--sandbox read-only` | Disallow file writes during the review |
| `-c 'KEY="VAL"'` | Override config (`sandbox_mode`, `approval_policy`, `model_reasoning_effort`, ...) |
| `--ephemeral` | Don't persist session to `~/.codex/sessions/` |
| `--skip-git-repo-check` | Allow running outside a git repo (needed for diff files) |
| `-o <FILE>` | Write only the final assistant message to this file |
| `-m <MODEL>` | Override the configured model for this run |
| `-C, --cd <DIR>` | Change working directory before running |
| `-p, --profile <NAME>` | Use a named profile from config.toml |
| `--json` | Emit JSONL event stream on stdout |
| `--output-schema <FILE>` | Constrain final answer to a JSON schema |

`codex exec review` (Mode 2) supports these confirmed common flags:
`-c/--config`, `-m/--model`, `--skip-git-repo-check`, `--ephemeral`,
`--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, and
`-o/--output-last-message`. It does **not** expose `-C/--cd`,
`-p/--profile`, `--profile-v2`, `-s/--sandbox`, `-i/--image`, `--add-dir`,
`--oss`, `--local-provider`, or `--color`. It adds review scope flags:
`--uncommitted`, `--base <BRANCH>`, `--commit <SHA>`, and `--title <T>`.

⚠️ **Mutually exclusive**: scope flag + positional `[PROMPT]`. Use Mode 2
for default review against a scope, Mode 1 (with manually-captured diff)
for custom prompts.

## Quick Decision Tree

- **Plan / design doc review** → Mode 1
- **Git scope (branch/commit/uncommitted) + Codex's default review prompt**
  → Mode 2
- **Git scope + your own focus list** → Mode 2-custom (capture diff +
  Mode 1)
- **Already inside a long session and codex appears stuck** → check
  `pgrep -af "codex exec"`, kill with `pkill -9 -f "codex exec"`,
  then either re-run with simpler prompt or proceed without the review

## Maintenance Note

Last verified on 2026-05-26 against Claude Code 2.1.150 and codex-cli 0.133.0;
re-check both versions plus `codex exec --help` / `codex exec review --help`.
