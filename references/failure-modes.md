# Codex failure modes & defenses

Read this when a codex review hangs, returns empty/stale output, or errors —
or when you're writing a **manual** invocation and need the timeout wrapper.
The bundled helper (`scripts/codex-review.sh`) already implements everything
here; you only need this file for manual one-offs or debugging.

## Always wrap codex in a kill-on-timeout

Codex has been observed to **hang silently for 30–40+ minutes** on some prompts
(suspected triggers: Unicode math symbols, transient OpenAI API stalls, very
long single-line prompts). The Bash tool's own `timeout` only bounds the Bash
call — if codex is backgrounded or the shell waits on the output file, the
native codex child keeps running. So always invoke through a process-tree
killer.

GNU `timeout` ships on Linux but **NOT macOS** (`brew install coreutils` gives
`gtimeout`). This auto-fallback works everywhere:

```bash
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill -KILL "$pid" 2>/dev/null || true
}

codex_with_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then gtimeout -k 5s "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then timeout -k 5s "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill -0 "$pid" 2>/dev/null && kill_tree "$pid" ) &
    local watchdog=$!
    wait "$pid"; local rc=$?
    kill "$watchdog" 2>/dev/null
    return $rc
  fi
}

# Canonical manual review call (note the </dev/null — see "stdin block"):
codex_with_timeout 600 codex exec --sandbox read-only \
  -c 'approval_policy="never"' --ephemeral --skip-git-repo-check \
  -o /tmp/codex-review-output.md "your prompt" </dev/null
```

If the wrapper fires, the `-o` file is 0-byte/partial. **Treat that as failure
and report it honestly** — never poll the output file indefinitely (a past
version of this skill hung the calling agent for tens of minutes doing that).

## stdin block

Even with the prompt passed as a positional argument, codex can block on
*"Reading additional input from stdin..."* and sit until the timeout fires —
burning the full budget for nothing. Always append `</dev/null` to
`codex exec` / `codex exec review`. (Confirmed on 0.141.0; the helper does it.)

## Recovery when codex is already wedged

```bash
pgrep -af "codex exec" | head           # find the binary + node/zsh wrappers
pkill -9 -f "codex exec" 2>/dev/null     # kill them all
pgrep -af "codex exec"                   # confirm empty before retrying
```

**Per-session propagation**: per upstream (openai/codex
[#24407](https://github.com/openai/codex/issues/24407)) the wedge is
session-level — once one invocation hangs in a shell, subsequent ones in that
same shell may hang too. Confirm `pgrep` is empty before retrying; if you
launched codex from a shell still in your task list, kill that shell too.

## Prompt hygiene — avoid the hang traps

Real hangs against codex 0.133 traced to one or more of:

- **Unicode math / superscripts** (`σ²`, `β`, `X'X`, `²`, `√`, `≤`) — suspected
  shell-escape/tokenizer interaction. Use ASCII: `sigma2`, `beta`, `XtX`,
  `sqrt`, `<=`.
- **Very long single-line prompts** (>2000 chars). Multi-line via real newlines
  is fine; giant one-liners are not. If the focus list is long, write it to a
  file and tell codex to read it.
- **Embedded LaTeX / backtick-heavy math** — same fix (ASCII or a file).
- **Competing shell-escape layers** (double-quote in single-quote in zsh
  `eval`) — codex's argv parser can stall. Prefer a here-doc to a temp file:

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
  -o /tmp/codex-review-output.md "$(cat /tmp/codex-prompt.txt)" </dev/null
```

## Empty or stale output

- **Empty / 0 bytes** after the command returns (or `timeout` exit 124): don't
  poll-wait. Report "Codex review produced no output — likely timed out or hit
  an API error" and proceed without it (or retry with a simpler/shorter prompt).
- **Stale**: the `-o` file sometimes contains a *prior session's* review when
  codex partially fails. Always sanity-check the first finding's `file:line`
  against the actual diff before trusting the rest; re-run on the fresh diff if
  it looks load-bearing.

## Known upstream bugs (codex 0.130–0.133)

Reference these in commit messages / status reports so the team can track
upstream fixes.

| Issue | Affects | Defense |
|-------|---------|---------|
| [#24407](https://github.com/openai/codex/issues/24407) `apply_patch`/`file_change` deadlocks (kind:add wedges, no `turn.completed`) | All 0.125–0.133 | `codex_with_timeout` kills the process tree |
| [#24278](https://github.com/openai/codex/issues/24278) Linux bwrap sandboxed `exec_command` fails | 0.131–0.133 (Linux) | Force `--sandbox read-only` (no bwrap exec); if bwrap errors persist, set `-c 'sandbox_mode="workspace-write"'` (output still via `-o`) |
| [#24388](https://github.com/openai/codex/issues/24388) Remote compaction deadlocks with image payloads | All recent | Don't pass `-i/--image` to reviews; this skill never does |
| [#24341/#24407](https://github.com/openai/codex/issues/24407) Symlinked-install sandbox init failure | Linux when codex lives under `~/.local/bin` | On repeated bwrap errors, `which codex` and confirm it's the real binary, not a symlink |
