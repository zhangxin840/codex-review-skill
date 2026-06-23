# codex CLI flag reference & maintenance

Read this when you need to confirm a flag exists, adapt a manual invocation, or
re-verify the skill against a new codex release.

## Verified flags

`codex exec` (free-form prompt / Mode 1):

| Flag | Purpose |
|------|---------|
| `--sandbox read-only` | Disallow file writes during the review |
| `-c 'KEY="VAL"'` | Override config (`sandbox_mode`, `approval_policy`, `model_reasoning_effort`, …) |
| `--ephemeral` | Don't persist the session to `~/.codex/sessions/` |
| `--skip-git-repo-check` | Allow running outside a git repo (needed for diff files) |
| `-o <FILE>` | Write only the final assistant message to this file |
| `-m <MODEL>` | Override the configured model for this run |
| `-C, --cd <DIR>` | Change working directory before running |
| `-p, --profile <NAME>` | Use a named profile from config.toml |
| `--json` | Emit a JSONL event stream on stdout |
| `--output-schema <FILE>` | Constrain the final answer to a JSON schema |

`codex exec review` (scoped review / Mode 2) supports: `-c/--config`,
`-m/--model`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`,
`--ignore-rules`, `--output-schema`, `--json`, `-o/--output-last-message`, plus
scope flags `--uncommitted`, `--base <BRANCH>`, `--commit <SHA>`, `--title <T>`.
It does **not** expose `-C/--cd`, `-p/--profile`, `--profile-v2`, `-s/--sandbox`,
`-i/--image`, `--add-dir`, `--oss`, `--local-provider`, or `--color`.

⚠️ **Scope flag + positional `[PROMPT]` are mutually exclusive**
(`error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'`). Use a
scope flag for codex's built-in review prompt; for a custom focus prompt against
a scope, capture the diff to a file and run plain `codex exec` (the helper's
`*-custom` modes do this). This mutual exclusion was not relaxed in any 0.134
alpha.

## Version history

- Verified 2026-05-26 against Claude Code 2.1.150 and codex-cli **0.133.0**.
- Re-confirmed 2026-06-23 on codex-cli **0.141.0**: the read-only review path is
  unchanged; added the `</dev/null` stdin-block guard after observing it there.
- `-o/--output-last-message` landed in 0.119; `codex exec review` in 0.130;
  `--full-auto` deprecated in 0.128.

## Re-verification checklist

```bash
codex --version
npm view @openai/codex version       # latest stable
npm view @openai/codex dist-tags     # latest + alpha channels
codex exec --help | head -60
codex exec review --help | head -60
codex doctor 2>&1 | tail -5          # auth/runtime health (0.131+)
```

Bump the **Known upstream bugs** table in `failure-modes.md` when issues
#24407 / #24278 / #24388 close ([openai/codex/issues](https://github.com/openai/codex/issues)).
Bump the flag table above when `--help` shows new flags. Cadence: re-verify on
each codex minor bump (~weekly as of 2026-05) or whenever a fresh hang/error
shows up in production.
