#!/bin/bash
# Codex Review Helper
# Usage: codex-review.sh <mode> [input_file]
#   mode: "plan" or "code"
#   input_file: path to content to review (default: /tmp/codex-review-input.md)

set -euo pipefail

MODE="${1:-plan}"
INPUT_FILE="${2:-/tmp/codex-review-input.md}"

if ! command -v codex &>/dev/null; then
  echo "Error: codex CLI not found. Install with: npm i -g @openai/codex" >&2
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: Input file not found: $INPUT_FILE" >&2
  exit 1
fi

case "$MODE" in
  plan)
    PROMPT="You are reviewing an implementation plan. Read $INPUT_FILE and evaluate it.

Focus on:
1. Risks: What could go wrong? Missing error handling, race conditions, breaking changes?
2. Gaps: Are there steps missing? Dependencies not accounted for?
3. Alternatives: Is there a simpler or more robust approach to any step?
4. Order: Are the steps in the right sequence? Any parallelization opportunities?

Be specific and actionable. If everything looks solid, say so briefly — don't manufacture issues.
Output your review in markdown."
    ;;
  code)
    PROMPT="You are reviewing code changes. Read $INPUT_FILE (a git diff or source code).

Focus on:
1. Bugs: Logic errors, cross-references that don't match, broken contracts
2. Consistency: Do all files agree on the same terminology and data flow?
3. Gaps: What happens in failure cases? Missing fallbacks?
4. Backward compatibility: Could these changes break existing behavior?

For each issue, specify the file and context. Rate severity: critical / warning / suggestion.
If the code looks good, say so — don't manufacture issues.
Output your review in markdown."
    ;;
  *)
    echo "Error: Unknown mode '$MODE'. Use 'plan' or 'code'." >&2
    exit 1
    ;;
esac

codex exec \
  --sandbox read-only \
  --full-auto \
  "$PROMPT" \
  2>/dev/null

# Cleanup
rm -f "$INPUT_FILE"
