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
#
#   codex-review.sh git-base <branch>
#       Review all changes on the current branch vs <branch>.
#
#   codex-review.sh git-commit <sha>
#       Review the changes introduced by a single commit.
#
# Output is written to /tmp/codex-review-output.md and echoed to stdout.

set -euo pipefail

MODE="${1:-plan}"
DEFAULT_INPUT="/tmp/codex-review-input.md"
OUTPUT_FILE="/tmp/codex-review-output.md"

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
if [[ "$MODE" == git-* ]] && ! codex exec review --help &>/dev/null; then
  echo "Error: codex CLI too old — 'codex exec review' subcommand missing. Upgrade to 0.130+ or use 'code' mode with a captured diff." >&2
  exit 1
fi

# Clear stale output so a previous run can't masquerade as the current one.
rm -f "$OUTPUT_FILE"

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

run_codex_exec() {
  # $1 = prompt
  # --skip-git-repo-check: plan/code modes are explicitly the non-git path (patch files, design docs).
  codex exec \
    --sandbox read-only \
    --ephemeral \
    --skip-git-repo-check \
    -o "$OUTPUT_FILE" \
    "$1"
}

run_codex_review() {
  # $@ = review-subcommand args (e.g. --uncommitted, --base main, --commit <sha>)
  codex exec review \
    -c 'sandbox_mode="read-only"' \
    --ephemeral \
    -o "$OUTPUT_FILE" \
    "$@" \
    "$FOCUS_CODE"
}

# Only the default scratch path is auto-deleted. Caller-supplied paths are preserved.
cleanup_default_input() {
  if [[ "${1:-}" == "$DEFAULT_INPUT" ]]; then
    rm -f "$DEFAULT_INPUT"
  fi
}

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
    run_codex_review --uncommitted --title "Working tree review ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown branch'))"
    ;;

  git-base)
    BASE="${2:?Error: usage: codex-review.sh git-base <branch>}"
    run_codex_review --base "$BASE" --title "Branch review: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD) vs $BASE"
    ;;

  git-commit)
    SHA="${2:?Error: usage: codex-review.sh git-commit <sha>}"
    run_codex_review --commit "$SHA" --title "Commit review: $SHA"
    ;;

  *)
    echo "Error: Unknown mode '$MODE'." >&2
    echo "Modes: plan | code | git-uncommitted | git-base <branch> | git-commit <sha>" >&2
    exit 1
    ;;
esac

# Echo the review to stdout for convenience
if [[ -s "$OUTPUT_FILE" ]]; then
  cat "$OUTPUT_FILE"
else
  echo "Warning: codex produced no final message. Re-run without -o to see the raw stream." >&2
  exit 2
fi
