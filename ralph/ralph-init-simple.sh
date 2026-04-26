#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# ralph-init-simple.sh — generate implementation_plan.md from a brief
# task description, without the spec-file overhead of ralph-init.sh.
#
# Suitable for scoped tasks: bug fixes, single features, ports.
# For larger projects that benefit from an interview + full spec,
# use description_prompt.md + ralph-init.sh instead.
#
# Usage:
#   ./ralph-init-simple.sh "fix readline crash on empty input" [output.md]
#   ./ralph-init-simple.sh task.md                             [output.md]
#
# TASK may be a literal string or a path to a file. Either way, its
# contents are substituted for the <TASK DESCRIPTION HERE> placeholder
# in simple_plan_prompt.md and piped to Sonnet.
#
# Environment variables:
#   RALPH_DIR     — directory containing simple_plan_prompt.md
#                   (default: script dir)
#   SONNET_MODEL  — model to use (default: sonnet)
#   CLAUDE_FLAGS  — extra flags passed to `claude` (e.g. in the sandbox
#                   container this is "--dangerously-skip-permissions")
#   RALPH_LOG     — per-run log that captures Sonnet's streaming stdout
#                   (default: ralph-init-<ts>.log, one per invocation).
#                   Tail this while the plan is being generated to watch
#                   Sonnet's output live:
#                     tail -f ralph-init-YYYYMMDD-HHMMSS.log
# ──────────────────────────────────────────────────────────────────────

TASK="${1:?Usage: $0 <task description or file> [output.md]}"
OUTPUT="${2:-implementation_plan.md}"
RALPH_DIR="${RALPH_DIR:-$(cd "$(dirname "$0")" && pwd)}"
TEMPLATE="$RALPH_DIR/simple_plan_prompt.md"
SONNET_MODEL="${SONNET_MODEL:-sonnet}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"
LOG="${RALPH_LOG:-ralph-init-$(date +%Y%m%d-%H%M%S).log}"

if [ ! -f "$TEMPLATE" ]; then
    echo "Error: template not found: $TEMPLATE" >&2
    exit 1
fi

: > "$LOG"
{
    echo ""
    echo "=== [$(date '+%H:%M:%S')] Sonnet simple plan generation ==="
} >> "$LOG"

echo "Streaming claude output → $LOG (tail -f to watch)"

# Write the task to a temp file so awk can stream it in regardless of
# whether the caller passed a string or a file path.
TASK_FILE=$(mktemp)
trap 'rm -f "$TASK_FILE"' EXIT

if [ -f "$TASK" ]; then
    cp "$TASK" "$TASK_FILE"
else
    printf '%s' "$TASK" > "$TASK_FILE"
fi

awk -v desc="$TASK_FILE" '
    /<TASK DESCRIPTION HERE>/ {
        while ((getline line < desc) > 0) print line
        close(desc)
        next
    }
    { print }
' "$TEMPLATE" \
    | claude -p $CLAUDE_FLAGS --model "$SONNET_MODEL" \
    | tee -a "$LOG" > "$OUTPUT"

echo "Wrote $OUTPUT"
