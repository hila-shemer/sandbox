#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# ralph-init.sh — generate implementation_plan.md from a project spec
#
# Substitutes the contents of <project_description.md> for the
# <DESCRIBE YOUR PROJECT HERE> placeholder in plan_prompt.md, then
# pipes the result to Opus to produce an implementation plan.
#
# Usage:
#   ./ralph-init.sh <project_description.md> [output.md]
#
# Environment variables:
#   RALPH_DIR     — directory containing plan_prompt.md (default: script dir)
#   OPUS_MODEL    — model to use (default: opus)
#   CLAUDE_FLAGS  — extra flags passed to `claude` (e.g. in the sandbox
#                   container this is "--dangerously-skip-permissions")
#   RALPH_LOG     — per-run log that captures Opus's streaming stdout
#                   (default: ralph-init-<ts>.log, one per invocation).
#                   Tail this while the plan is being generated to watch
#                   Opus's output live:
#                     tail -f ralph-init-YYYYMMDD-HHMMSS.log
# ──────────────────────────────────────────────────────────────────────

PROJECT="${1:?Usage: $0 <project_description.md> [output.md]}"
OUTPUT="${2:-implementation_plan.md}"
RALPH_DIR="${RALPH_DIR:-$(cd "$(dirname "$0")" && pwd)}"
TEMPLATE="$RALPH_DIR/plan_prompt.md"
OPUS_MODEL="${OPUS_MODEL:-opus}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"
LOG="${RALPH_LOG:-ralph-init-$(date +%Y%m%d-%H%M%S).log}"

if [ ! -f "$PROJECT" ]; then
    echo "Error: project description not found: $PROJECT" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
    echo "Error: template not found: $TEMPLATE" >&2
    exit 1
fi

: > "$LOG"
{
    echo ""
    echo "=== [$(date '+%H:%M:%S')] Opus plan generation ==="
} >> "$LOG"

echo "Streaming claude output → $LOG (tail -f to watch)"

# tee captures Opus's output to the run log for live tailing while also
# forwarding it to $OUTPUT. `set -o pipefail` ensures a claude failure
# propagates through tee.
awk -v desc="$PROJECT" '
    /<DESCRIBE YOUR PROJECT HERE>/ {
        while ((getline line < desc) > 0) print line
        close(desc)
        next
    }
    { print }
' "$TEMPLATE" \
    | claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL" \
    | tee -a "$LOG" > "$OUTPUT"

echo "Wrote $OUTPUT"
