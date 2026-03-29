# Codex Review Skill

A Claude Code skill that uses [OpenAI Codex CLI](https://github.com/openai/codex) (GPT-5.x) as an independent code/plan reviewer, with built-in verification to filter false positives.

## What it does

- Runs Codex in read-only sandbox mode to review plans or code diffs
- Claude verifies each Codex finding against the actual code before fixing
- Produces a verification table (Confirmed / False Positive / Noted)
- Commits with audit trail documenting what was found and fixed

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

## Files

```
codex-review/
├── SKILL.md                    # Skill instructions (156 lines)
└── scripts/
    └── codex-review.sh         # Helper script for plan/code review
```

## License

MIT
