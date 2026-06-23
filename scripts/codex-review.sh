#!/bin/bash
# Codex Review Helper
#
# Usage:
#   codex-review.sh plan [input_file]
#       Review a free-form plan/design doc. Default input_file: /tmp/codex-review-input.md
#
#   codex-review.sh code [input_file]
#       Review a diff or source captured into input_file. Default: /tmp/codex-review-input.md
#       Use this when the diff isn't a git working tree (e.g., a patch file).
#
#   codex-review.sh git-uncommitted
#       Review staged + unstaged + untracked changes in the current git repo.
#       (Uses Codex's built-in review prompt; custom focus not possible — see "Why")
#
#   codex-review.sh git-base <branch>
#       Review all changes on the current branch vs <branch>.
#       (Uses Codex's built-in review prompt; custom focus not possible — see "Why")
#
#   codex-review.sh git-commit <sha>
#       Review the changes introduced by a single commit.
#       (Uses Codex's built-in review prompt; custom focus not possible — see "Why")
#
#   codex-review.sh git-base-custom <branch>
#       Same scope as git-base but allows the FOCUS_CODE custom prompt by
#       capturing the diff into a file first and running plain `codex exec`.
#       Use when you want both a specific git scope AND a custom focus list.
#
#   codex-review.sh git-uncommitted-custom
#       Same scope as git-uncommitted but allows the FOCUS_CODE custom prompt.
#       Includes staged, unstaged, and untracked file contents.
#
#   codex-review.sh git-commit-custom <sha>
#       Same scope as git-commit but allows the FOCUS_CODE custom prompt.
#
#   codex-review.sh --help
#       Print this usage summary without running Codex.
#
# Why the split: codex 0.133's `codex exec review` rejects a positional
# PROMPT when a scope flag (--base/--uncommitted/--commit) is given:
#   error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'
# git-base / git-uncommitted / git-commit modes therefore use Codex's
# default review prompt; the "*-custom" variants capture the diff and
# fall back to the prompt-allowed `codex exec` path.
#
# Output is written to /tmp/codex-review-output.md and echoed to stdout.
#
# All codex invocations are wrapped with a portable timeout (default 600s)
# to prevent the multi-minute hangs observed on prompts containing Unicode
# math symbols or under transient OpenAI API stalls.

set -euo pipefail

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

MODE="${1:-plan}"
DEFAULT_INPUT="${CODEX_REVIEW_INPUT:-/tmp/codex-review-input.md}"
OUTPUT_FILE="${CODEX_REVIEW_OUTPUT:-/tmp/codex-review-output.md}"
TIMEOUT_SECS="${CODEX_REVIEW_TIMEOUT:-600}"  # 10 min default; override via env

if ! command -v codex &>/dev/null; then
  echo "Error: codex CLI not found. Install with: brew install --cask codex (or: npm i -g @openai/codex)" >&2
  exit 1
fi

# Capability guard: -o/--output-last-message landed in codex 0.119; without it the script can't capture output.
if ! codex exec --help 2>/dev/null | grep -q -- '--output-last-message'; then
  echo "Error: codex CLI too old — missing -o/--output-last-message. Upgrade to 0.119+." >&2
  exit 1
fi

# Mode-gated guard: git-* modes require the `codex exec review` subcommand (0.130+).
if [[ "$MODE" == git-* ]] && [[ "$MODE" != *-custom ]] && ! codex exec review --help &>/dev/null; then
  echo "Error: codex CLI too old — 'codex exec review' subcommand missing. Upgrade to 0.130+ or use 'code' mode with a captured diff." >&2
  exit 1
fi

# Clear stale output so a previous run can't masquerade as the current one.
rm -f "$OUTPUT_FILE"

# Track codex's exit code separately. T5 (2026-05-26 validation) caught:
# without this, a timeout (rc=143 SIGTERM) propagates through set -e and the
# script exits 143 instead of reaching the documented "empty output → exit 2"
# branch. The OUTPUT_FILE check below is the authoritative success signal.
CODEX_RC=0
# Temporarily disable -e so the dispatcher case can complete even when the
# embedded codex call exits non-zero. We re-enable -e after the case.
set +e

# --- Portable timeout wrapper ----------------------------------------------
# macOS doesn't ship GNU `timeout`; coreutils provides `gtimeout`. Fall back
# to a shell watchdog when neither is present. The fallback kills the process
# tree, not just the parent wrapper, because codex's node shim launches a
# native binary child.
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

with_timeout() {
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
    wait "$watchdog" 2>/dev/null || true
    return $rc
  fi
}

# --- Prompts ----------------------------------------------------------------

FOCUS_PLAN="Focus on:
1. Risks: What could go wrong? Missing error handling, race conditions, breaking changes?
2. Gaps: Are there steps missing? Dependencies not accounted for?
3. Alternatives: Is there a simpler or more robust approach to any step?
4. Order: Are the steps in the right sequence? Any parallelization opportunities?

Be specific and actionable. If everything looks solid, say so briefly — don't manufacture issues.
Output your review in markdown."

FOCUS_CODE="Focus on:
1. Bugs: Logic errors, cross-references that don't match, broken contracts
2. Consistency: Do all files agree on the same terminology and data flow?
3. Gaps: What happens in failure cases? Missing fallbacks?
4. Backward compatibility: Could these changes break existing behavior?

For each issue, specify the file and context. Rate severity: critical / warning / suggestion.
If the code looks good, say so — don't manufacture issues.
Output your review in markdown."

# --- Runners ----------------------------------------------------------------

run_codex_exec() {
  # $1 = prompt
  # --skip-git-repo-check: plan/code/*-custom modes are explicitly non-git path.
  # -c approval_policy="never": prevent TTY stalls if user config requires approval.
  # </dev/null: codex otherwise blocks on "Reading additional input from stdin..."
  #   even though the prompt is a positional arg — without it the call burns the
  #   full timeout instead of returning (observed on codex 0.141.0).
  with_timeout "$TIMEOUT_SECS" codex exec \
    --sandbox read-only \
    -c 'approval_policy="never"' \
    --ephemeral \
    --skip-git-repo-check \
    -o "$OUTPUT_FILE" \
    "$1" \
    </dev/null
}

run_codex_review_default_prompt() {
  # $@ = review-subcommand args (e.g. --uncommitted, --base main, --commit <sha>)
  # NOTE: codex 0.133 rejects [PROMPT] together with --base/--uncommitted/--commit.
  # We therefore don't append FOCUS_CODE here — Codex's built-in review prompt
  # applies. For custom focus, use the *-custom modes which capture diff + exec.
  # </dev/null: same stdin-block guard as run_codex_exec.
  with_timeout "$TIMEOUT_SECS" codex exec review \
    -c 'sandbox_mode="read-only"' \
    -c 'approval_policy="never"' \
    --ephemeral \
    -o "$OUTPUT_FILE" \
    "$@" \
    </dev/null
}

# Only the default scratch path is auto-deleted. Caller-supplied paths are preserved.
cleanup_default_input() {
  if [[ -z "${CODEX_REVIEW_INPUT:-}" && "${1:-}" == "$DEFAULT_INPUT" ]]; then
    rm -f "$DEFAULT_INPUT"
  fi
}

capture_uncommitted_diff() {
  local output="$1"

  {
    echo "# Uncommitted git changes"
    echo
    echo "## Status"
    git status --short --untracked-files=all || true
    echo
    echo "## Staged diff"
    git diff --cached --binary || true
    echo
    echo "## Unstaged tracked diff"
    git diff --binary || true
    echo
    echo "## Untracked file contents"

    local file
    while IFS= read -r file; do
      [[ -n "$file" && -f "$file" ]] || continue
      echo
      echo "### $file"
      git diff --no-index --binary -- /dev/null "$file" || true
    done < <(git ls-files --others --exclude-standard 2>/dev/null || true)
  } > "$output"
}

# --- Mode dispatch ----------------------------------------------------------

case "$MODE" in
  plan)
    INPUT_FILE="${2:-$DEFAULT_INPUT}"
    [[ -f "$INPUT_FILE" ]] || { echo "Error: Input file not found: $INPUT_FILE" >&2; exit 1; }
    run_codex_exec "You are reviewing an implementation plan. Read $INPUT_FILE and evaluate it.

$FOCUS_PLAN"
    cleanup_default_input "$INPUT_FILE"
    ;;

  code)
    INPUT_FILE="${2:-$DEFAULT_INPUT}"
    [[ -f "$INPUT_FILE" ]] || { echo "Error: Input file not found: $INPUT_FILE" >&2; exit 1; }
    run_codex_exec "You are reviewing code changes. Read $INPUT_FILE (a diff or source).

$FOCUS_CODE"
    cleanup_default_input "$INPUT_FILE"
    ;;

  git-uncommitted)
    run_codex_review_default_prompt --uncommitted \
      --title "Working tree review ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown branch'))"
    ;;

  git-base)
    BASE="${2:?Error: usage: codex-review.sh git-base <branch>}"
    run_codex_review_default_prompt --base "$BASE" \
      --title "Branch review: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD) vs $BASE"
    ;;

  git-commit)
    SHA="${2:?Error: usage: codex-review.sh git-commit <sha>}"
    run_codex_review_default_prompt --commit "$SHA" \
      --title "Commit review: $SHA"
    ;;

  git-uncommitted-custom)
    capture_uncommitted_diff "$DEFAULT_INPUT"
    run_codex_exec "You are reviewing uncommitted git working-tree changes. Read $DEFAULT_INPUT.

$FOCUS_CODE"
    cleanup_default_input "$DEFAULT_INPUT"
    ;;

  git-base-custom)
    BASE="${2:?Error: usage: codex-review.sh git-base-custom <branch>}"
    git diff --binary "${BASE}..HEAD" > "$DEFAULT_INPUT"
    run_codex_exec "You are reviewing all changes on $(git rev-parse --abbrev-ref HEAD 2>/dev/null) vs $BASE.
Read the diff at $DEFAULT_INPUT.

$FOCUS_CODE"
    cleanup_default_input "$DEFAULT_INPUT"
    ;;

  git-commit-custom)
    SHA="${2:?Error: usage: codex-review.sh git-commit-custom <sha>}"
    git show --binary "$SHA" > "$DEFAULT_INPUT"
    run_codex_exec "You are reviewing the changes introduced by commit $SHA.
Read the diff at $DEFAULT_INPUT.

$FOCUS_CODE"
    cleanup_default_input "$DEFAULT_INPUT"
    ;;

  *)
    echo "Error: Unknown mode '$MODE'." >&2
    echo "Modes: plan | code | git-uncommitted | git-base <branch> | git-commit <sha>" >&2
    echo "       git-uncommitted-custom | git-base-custom <branch> | git-commit-custom <sha>" >&2
    exit 1
    ;;
esac
CODEX_RC=$?
set -e

# Echo the review to stdout for convenience
if [[ -s "$OUTPUT_FILE" ]]; then
  cat "$OUTPUT_FILE"
else
  # Empty output = wedge (#24407) or upstream API stall. Per upstream
  # observations the hang is session-level, so blind in-process retry usually
  # won't help — but we kill any stale codex procs first so an external
  # operator-triggered retry has a clean slate.
  pkill -9 -f "codex exec" 2>/dev/null || true
  echo "Warning: codex produced no final message — likely timed out (${TIMEOUT_SECS}s), hit OpenAI API stall, or wedged on apply_patch deadlock (openai/codex#24407)." >&2
  echo "Stale 'codex exec' processes killed. To retry:" >&2
  echo "  1. Confirm clean shell: pgrep -af 'codex exec'  # should be empty" >&2
  echo "  2. Re-run with: smaller scope, ASCII-only prompt, or higher CODEX_REVIEW_TIMEOUT (current: ${TIMEOUT_SECS}s)" >&2
  echo "  3. If repeatedly fails: try in a fresh shell; per-session wedges are documented upstream." >&2
  exit 2
fi
