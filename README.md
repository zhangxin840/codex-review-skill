# Codex Review Skill

A Claude Code user-level skill that uses [OpenAI Codex CLI](https://github.com/openai/codex) as an independent code/plan reviewer, with built-in verification to filter false positives.

Current local baseline: Claude Code 2.1.150 and codex-cli 0.133.0.

## What it does

- Runs Codex in read-only sandbox mode to review plans or code diffs
- Uses a portable timeout wrapper so hung Codex reviews do not wedge Claude Code
- Supports both Codex's default `exec review` prompt and custom-focus reviews via captured diffs
- Claude verifies each Codex finding against the actual code before fixing
- Produces a verification table (Confirmed / Partially Valid / False Positive / Noted / Stale)
- Can include an audit trail in commits documenting what was found and fixed

## Why two models?

Two different model families catch different issues. Codex excels at cross-file consistency (catching when File A contradicts File B). Claude excels at understanding why something is designed a certain way. The verify-then-fix protocol combines both strengths.

## Install

```bash
# Install Codex CLI (prerequisite)
npm i -g @openai/codex
codex login

# Install this skill (Claude Code)
claude skill add codex-review --from git@github.com:zhangxin840/codex-review-skill.git
```

Or manually copy `SKILL.md` and `scripts/` to `~/.claude/skills/codex-review/`.

## Usage

In Claude Code, say any of:
- "codex review"
- "用 codex 审一下"
- "交叉验证"
- "让 codex 看看这些改动"
- "double check with codex"

Claude will automatically capture the relevant diff, run Codex, verify findings, and present results.

You can also invoke the helper directly:

```bash
~/.claude/skills/codex-review/scripts/codex-review.sh --help
~/.claude/skills/codex-review/scripts/codex-review.sh git-uncommitted
~/.claude/skills/codex-review/scripts/codex-review.sh git-base main
~/.claude/skills/codex-review/scripts/codex-review.sh git-base-custom main
```

Use the `*-custom` modes when you need your own focus prompt. Codex 0.133 rejects a positional prompt together with `--base`, `--uncommitted`, or `--commit` on `codex exec review`, so the helper captures the diff and runs plain `codex exec` for those cases.

## Files

```
codex-review/
├── SKILL.md                    # Skill instructions
└── scripts/
    └── codex-review.sh         # Helper: plan | code | git-* | git-*-custom
```

## License

MIT
