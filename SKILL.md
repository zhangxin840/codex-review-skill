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
different issues is more reliable than one model reviewing itself: Codex finds
issues, Claude verifies each before fixing. The verification step is
non-negotiable because Codex has a ~15–20% false-positive rate on complex diffs.

> Not the same as `/code-review` or `/review` — those are *Claude* reviewing the
> diff. This skill dispatches to *Codex*, a different model family. Reach for it
> when the user wants a genuine second opinion or cross-validation.

## When to proactively suggest

Even unprompted, consider offering a Codex review when:
- a multi-file refactor touched 5+ files with cross-references (contracts, configs, schemas)
- an architectural change altered terminology or data flow across the codebase
- a release is being prepared and the changes haven't been independently reviewed

Skip it for trivial changes (typos, single-file edits, docs-only).

## Prerequisites

```bash
which codex && codex --version    # need 0.130+
codex doctor 2>&1 | tail -5       # auth/runtime health (0.131+)
# install: brew install --cask codex   OR   npm i -g @openai/codex
```

Verified against codex-cli 0.133.0 and re-confirmed on 0.141.0. Full flag
reference and re-verification steps: `references/codex-cli.md`.

## Run it: prefer the helper

The bundled helper centralizes the current flags, the kill-on-timeout wrapper,
the `</dev/null` stdin guard, stale-output cleanup, and diff capture — so you
don't have to get all of that right by hand. **It is the single source of truth
for how to invoke codex; use it unless you're debugging the helper itself.**

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" --help            # all modes

# Plan / design doc (or any non-git content): write it to a file first
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" plan /tmp/codex-review-input.md
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" code /tmp/diff.patch

# Git scope, Codex's built-in review prompt:
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-uncommitted
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-base main
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-commit <SHA>

# Git scope + YOUR own focus prompt (captures the diff, then runs codex exec):
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-base-custom main
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-uncommitted-custom
"${CLAUDE_SKILL_DIR}/scripts/codex-review.sh" git-commit-custom <SHA>
```

The helper echoes Codex's final review to stdout and also writes it to
`${CODEX_REVIEW_OUTPUT:-/tmp/codex-review-output.md}`. Tune the timeout with
`CODEX_REVIEW_TIMEOUT` (default 600s).

**If the helper prints an empty-output warning, the review FAILED** (timeout /
API stall / wedge) — do not invent a review. See `references/failure-modes.md`
for recovery (`pkill -9 -f "codex exec"`, then retry smaller/simpler).

Manual invocation (only when adapting a one-off or debugging the helper)
requires the portable timeout wrapper and the stdin guard — both are in
`references/failure-modes.md`. Don't hand-roll a bare `codex exec`; on macOS
there's no `timeout` and a bare call can hang for tens of minutes.

## Choosing a mode

- **Plan / design doc, or a custom prompt against a specific diff** → `plan`
  (or `*-custom` for a git scope). `codex exec review` can't take a custom
  prompt together with a scope flag, so a custom focus always goes through the
  capture-diff-then-`codex exec` path.
- **Git scope, trust Codex's default review prompt** → `git-uncommitted` /
  `git-base` / `git-commit`. Reviews staged+unstaged+untracked / branch-vs-base
  / a single commit respectively.
- **A patch file or non-git diff** → `code`.

`--base`/`--uncommitted`/`--commit` and a positional `[PROMPT]` are mutually
exclusive in codex — that's why the custom modes exist (details in
`references/codex-cli.md`).

## Ground the review prompt

Codex is far more useful asked to check specific invariants than given a vague
"review for bugs". For custom prompts (`plan` / `*-custom`):

- **Pre-compute the evidence into the input file.** Don't make Codex hunt —
  hand it the diff *plus* the output of the checks a good reviewer would run:
  dependency cross-checks, greps for leftover/stale references, before/after of
  files you edited, a one-line statement of intent. Then tell it *"rely on this
  file; only spot-read a few files to confirm, don't scan whole repos."* This
  both sharpens findings and stops Codex from wandering (which causes timeouts).
- **For multi-repo or large reviews**, this matters most: `cd` into one git repo,
  pass the scope through the input file, and keep Codex from crawling every tree.
- **Declare exclusions up front** — if the diff is text-only, staged-only, or
  excludes binaries, say so, or Codex flags intentionally-missing artifacts.
- **Ask contract questions, not taste questions**: "does `T13_COLUMNS` match the
  customer schema and the e2e tests?" beats "is this design good?".
- **Before deleting anything Codex flags as unused** (a key/alias/metadata),
  grep for runtime readers first — some "leaked" keys are load-bearing contracts.

## Post-review: verify-then-fix protocol

After receiving Codex output, do NOT blindly apply fixes. Every finding is
verified first.

### Step 1 — Present the findings

```
## Codex Review (<Codex model from config — typically gpt-5.x>)
<Codex's review, lightly cleaned up if formatting is redundant>
---
*Reviewed by Codex CLI in read-only sandbox mode*
```

### Step 2 — Verify each finding against the actual files

```
For each finding:
  1. Read the specific file:line Codex references
  2. Check the issue actually exists (Codex may misread the diff)
  3. If it claims File A contradicts File B — read both and confirm
  4. Classify:
     - CONFIRMED:       real, needs fix
     - PARTIALLY VALID: real but severity/scope differs
     - FALSE POSITIVE:  Codex misread the code or context
     - NOTED:           valid observation, acceptable trade-off
     - STALE:           file:line doesn't match the current diff (likely a
                        prior session's cached output) — re-run on the fresh diff
```

Present a verification table:

| # | Codex Finding | Severity | Claude Verdict | Action |
|---|--------------|----------|---------------|--------|
| 1 | description… | critical | **Confirmed** | Fix: … |
| 2 | description… | warning | **False positive** | No action (reason) |

### Step 3 — Fix only what's real

Apply CONFIRMED and PARTIALLY VALID. Skip FALSE POSITIVE. Document NOTED items
in the commit. Re-run review on STALE findings that look load-bearing.

### Step 4 — Commit with an audit trail

```
fix: address Codex review findings — <summary>

Fixes N issues from Codex review (<Codex model>):
1. [severity] description — fix applied
2. [severity] description — fix applied

Not fixed (acceptable):
- description — reason

Co-Authored-By: Claude <noreply@anthropic.com>
```

Match the repo's existing `Co-Authored-By` convention rather than hardcoding one.

## Why verification matters

- **Codex's strength** — cross-file consistency: it catches File A saying X
  while File B says Y (a config calls something a hard gate but the code treats
  it as soft; an API contract defines one output path but the caller writes
  another).
- **Codex's weakness** — it over-reports on large diffs, conflates design
  choices with bugs, misses context that makes something intentional, and
  occasionally returns STALE output. Sanity-check the first finding's file:line
  against the real diff before trusting the rest.
- **~15–20% false positives** in practice. Skipping verification means fixing
  non-issues and introducing new bugs.

## Key constraints

- **Read-only, always.** The review must never modify files: `--sandbox
  read-only` (`codex exec`) or `-c 'sandbox_mode="read-only"'` (`codex exec
  review`). The user's default sandbox may be `workspace-write` — the explicit
  override matters. The helper does this for you.
- **`-c 'approval_policy="never"'`** so an unattended run can't stall on a TTY
  approval prompt. (Do **not** use the deprecated `--full-auto`.)
- **`--ephemeral`** — reviews are one-shot; don't pollute `~/.codex/sessions/`.
- **Capture with `-o <file>`, guard stdin with `</dev/null`, wrap in a
  timeout.** All three are in the helper; if you go manual, see
  `references/failure-modes.md` — skipping any of them risks empty output or a
  multi-minute hang.
- **Empty output = failure, not "looks clean".** Report it honestly and proceed
  without the review (or retry simpler). Never poll-wait on the output file.
- **Clean up** `/tmp/codex-review-*.md` after manual reviews (the helper cleans
  its own default scratch input).

## Quick decision tree

- Plan / design doc → `plan`
- Git scope + Codex's default review prompt → `git-uncommitted` / `git-base` / `git-commit`
- Git scope + your own focus list → `git-*-custom`
- Patch file / non-git diff → `code`
- Codex appears stuck → `pgrep -af "codex exec"`, `pkill -9 -f "codex exec"`,
  confirm empty, then retry simpler or proceed without it
  (`references/failure-modes.md`)
