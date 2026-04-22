#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# ralph.sh — autonomous implementation loop
#
# Three-role architecture:
#   Planner  (Opus)  : decomposes plan into task slices
#   Reviewer (Opus)  : periodic mid-task review, catches drift
#   Executor (Sonnet): implements the current task slice
#
# Usage:
#   ./ralph.sh <implementation_plan.md>
#   ./ralph.sh <implementation_plan.md> --sonnet-only   # flat loop, no Opus
#
# Environment variables:
#   RALPH_DIR          — directory containing prompt files (default: script dir)
#   OPUS_MODEL         — model for planning/review (default: opus)
#   SONNET_MODEL       — model for execution (default: sonnet)
#   MAX_INNER          — max Sonnet iterations per task (default: 8)
#   MAX_OUTER          — max Opus planning cycles (default: 50)
#   REVIEW_INTERVAL    — Opus review every N Sonnet iterations (default: 4)
#   RALPH_LOG          — status log file path (default: ralph.log)
#   RALPH_RUN_LOG      — per-run streaming log of every `claude -p` call's
#                        stdout (default: ralph-run-<timestamp>.log, created
#                        in main()). Tail this to watch progress live:
#                          tail -f ralph-run-YYYYMMDD-HHMMSS.log
#   CLAUDE_FLAGS       — extra flags passed to every `claude` invocation.
#                        Inside the sandbox container this is preset to
#                        "--dangerously-skip-permissions" so tool use is
#                        auto-approved (the container is the permission boundary).
# ──────────────────────────────────────────────────────────────────────

PLAN="${1:?Usage: $0 <implementation_plan.md> [--sonnet-only]}"
SONNET_ONLY=false
[[ "${2:-}" == "--sonnet-only" ]] && SONNET_ONLY=true

# Resolve prompt directory (where the .md prompt files live)
RALPH_DIR="${RALPH_DIR:-$(cd "$(dirname "$0")" && pwd)}"

OPUS_MODEL="${OPUS_MODEL:-opus}"
SONNET_MODEL="${SONNET_MODEL:-sonnet}"
MAX_INNER="${MAX_INNER:-8}"
MAX_OUTER="${MAX_OUTER:-50}"
REVIEW_INTERVAL="${REVIEW_INTERVAL:-4}"
LOG="${RALPH_LOG:-ralph.log}"
# RUN_LOG is set in main() once per invocation, so every claude call in this
# run tees to the same timestamped file.
RUN_LOG="${RALPH_RUN_LOG:-}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"

# The installed `claude` CLI supports --output-format stream-json (with
# --print --verbose), but that emits JSON-wrapped chunks which are not ideal
# for human `tail -f`. We stick with the default text output; stdout already
# streams as Claude generates it.

# Prompt files
SONNET_PREFIX="$RALPH_DIR/sonnet_prefix.md"
SONNET_SUFFIX="$RALPH_DIR/sonnet_suffix.md"
OPUS_PLANNER="$RALPH_DIR/opus_planner.md"
OPUS_REVIEWER="$RALPH_DIR/opus_reviewer.md"

# ── Helpers ──────────────────────────────────────────────────────────

log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG"
}

# Write a header into the per-run streaming log so a `tail -f` watcher can
# tell which claude call's output they're looking at. Called just before
# each `claude -p` invocation.
run_log_header() {
  {
    echo ""
    echo "=== [$(date '+%H:%M:%S')] $* ==="
  } >> "$RUN_LOG"
}

status_line() {
  head -n 1 STATUS.md 2>/dev/null || echo ""
}

git_log_summary() {
  git log --oneline -30 2>/dev/null || echo "(no commits yet)"
}

test_summary() {
  # Best-effort snapshot of last test run. Adapt per project.
  if [[ -f test_results.txt ]]; then
    tail -20 test_results.txt
  else
    echo "(no test results file found)"
  fi
}

ensure_git() {
  if [[ ! -d .git ]]; then
    git init -q
    git add -A 2>/dev/null || true
    git commit -q -m "Initial state before ralph loop" --allow-empty
    log "Initialized git repo"
  fi
}

check_prompt_files() {
  local missing=()
  if [[ "$SONNET_ONLY" == true ]]; then
    for f in "$SONNET_PREFIX" "$SONNET_SUFFIX"; do
      [[ -f "$f" ]] || missing+=("$f")
    done
  else
    for f in "$SONNET_PREFIX" "$SONNET_SUFFIX" "$OPUS_PLANNER" "$OPUS_REVIEWER"; do
      [[ -f "$f" ]] || missing+=("$f")
    done
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing prompt files:"
    printf '  %s\n' "${missing[@]}"
    echo "Set RALPH_DIR to the directory containing them, or place them alongside this script."
    exit 1
  fi
}

# Assemble memory file context to pipe into Opus calls.
# Gives Opus a guaranteed baseline in its context window.
# Opus also has filesystem access and should verify by reading actual files.
memory_context() {
  echo ""
  echo "## Snapshot of Memory Files and Git State"
  echo ""
  echo "These are piped in for quick orientation. You ALSO have full filesystem"
  echo "access — use it to read source files, run tests, and verify Sonnet's"
  echo "actual work. Do not rely solely on these snapshots."
  echo ""
  echo "### STATUS.md"
  echo '```'
  cat STATUS.md 2>/dev/null || echo "(does not exist yet)"
  echo '```'
  echo ""
  echo "### DECISIONS.md"
  echo '```'
  cat DECISIONS.md 2>/dev/null || echo "(does not exist yet)"
  echo '```'
  echo ""
  echo "### PROBLEMS.md"
  echo '```'
  cat PROBLEMS.md 2>/dev/null || echo "(does not exist yet)"
  echo '```'
  echo ""
  echo "### CURRENT_TASK.md"
  echo '```'
  cat CURRENT_TASK.md 2>/dev/null || echo "(does not exist yet)"
  echo '```'
  echo ""
  echo "### Recent Git Log"
  echo '```'
  git_log_summary
  echo '```'
  echo ""
  echo "### Test Results (last 20 lines)"
  echo '```'
  test_summary
  echo '```'
}

# ── Opus reviewer (mid-task) ─────────────────────────────────────────

run_opus_review() {
  log "  >> Opus review (mid-task)"
  run_log_header "Opus reviewer (mid-task)"

  {
    cat "$OPUS_REVIEWER"
    echo ""
    echo "## Current Task Being Executed"
    echo ""
    cat CURRENT_TASK.md 2>/dev/null || echo "(no current task)"
    echo ""
    echo "---"
    memory_context
  } | claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL" 2>>"$LOG" | tee -a "$RUN_LOG"

  log "  << Opus review complete"
}

# ── Sonnet execution (inner loop) ───────────────────────────────────

run_sonnet() {
  local task_file="$1"
  local inner=0

  while (( inner < MAX_INNER )); do
    inner=$((inner + 1))
    log "  Sonnet iteration $inner / $MAX_INNER"
    run_log_header "Sonnet iteration $inner / $MAX_INNER"

    cat "$SONNET_PREFIX" "$task_file" "$SONNET_SUFFIX" \
      | claude -p $CLAUDE_FLAGS --model "$SONNET_MODEL" 2>>"$LOG" \
      | tee -a "$RUN_LOG"

    local status
    status=$(status_line)

    if [[ "$status" == "TASK_DONE" || "$status" == "DONE" ]]; then
      log "  Sonnet reports: $status"
      return 0
    elif [[ "$status" == BLOCKED* ]]; then
      log "  Sonnet reports BLOCKED — triggering Opus review"
      run_opus_review

      # After review, check if Opus unblocked it
      status=$(status_line)
      if [[ "$status" == BLOCKED* ]]; then
        log "  Still blocked after Opus review"
        return 1
      fi
      log "  Opus unblocked — continuing Sonnet loop"
      continue
    fi

    # Periodic Opus review every REVIEW_INTERVAL iterations
    if (( REVIEW_INTERVAL > 0 && inner % REVIEW_INTERVAL == 0 && inner < MAX_INNER )); then
      run_opus_review
    fi
  done

  log "  Sonnet hit max iterations ($MAX_INNER), escalating to planner"
  return 2
}

# ── Flat Sonnet-only mode ────────────────────────────────────────────

run_flat_loop() {
  local iteration=0
  while true; do
    iteration=$((iteration + 1))
    log "Iteration $iteration"
    run_log_header "Sonnet flat iteration $iteration"

    cat "$SONNET_PREFIX" "$PLAN" "$SONNET_SUFFIX" \
      | claude -p $CLAUDE_FLAGS --model "$SONNET_MODEL" 2>>"$LOG" \
      | tee -a "$RUN_LOG"

    local status
    status=$(status_line)

    if [[ "$status" == "DONE" ]]; then
      log "✓ Complete after $iteration iteration(s)"
      return 0
    elif [[ "$status" == BLOCKED* ]]; then
      log "✗ $status (after $iteration iterations)"
      return 1
    fi
  done
}

# ── Main: hierarchical loop with Opus planning ──────────────────────

run_hierarchical_loop() {
  local outer=0

  while (( outer < MAX_OUTER )); do
    outer=$((outer + 1))
    log "=== Opus planning cycle $outer ==="
    run_log_header "Opus planner cycle $outer"

    # Build Opus planner context
    {
      cat "$OPUS_PLANNER"
      echo ""
      echo "## Full Implementation Plan"
      echo ""
      cat "$PLAN"
      echo ""
      echo "---"
      memory_context
    } | claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL" 2>>"$LOG" \
      | tee -a "$RUN_LOG"

    # Check what Opus wrote
    local task_status
    task_status=$(head -n 1 CURRENT_TASK.md 2>/dev/null || echo "")

    if [[ "$task_status" == "COMPLETE" ]]; then
      log "✓ Opus declares project complete after $outer planning cycle(s)"
      return 0
    elif [[ "$task_status" == BLOCKED* ]]; then
      log "✗ Opus blocked: $task_status"
      return 1
    fi

    # Run Sonnet on the current task (with periodic reviews)
    run_sonnet CURRENT_TASK.md
    local sonnet_exit=$?

    # If Sonnet declared the whole project DONE
    if [[ "$(status_line)" == "DONE" ]]; then
      log "✓ Sonnet declares full project complete"
      return 0
    fi

    # Continue to next Opus planning cycle regardless —
    # planner will review the state and decide what's next
  done

  log "✗ Hit max planning cycles ($MAX_OUTER)"
  return 1
}

# ── Entry point ──────────────────────────────────────────────────────

main() {
  if [[ ! -f "$PLAN" ]]; then
    echo "Plan file not found: $PLAN"
    exit 1
  fi

  check_prompt_files
  ensure_git

  # One streaming log per run, created here so every claude call in this
  # invocation appends to the same file. Tail it in another pane:
  #   tail -f "$RUN_LOG"
  if [[ -z "$RUN_LOG" ]]; then
    RUN_LOG="ralph-run-$(date +%Y%m%d-%H%M%S).log"
  fi
  : > "$RUN_LOG"

  echo "" >> "$LOG"
  log "═══ Ralph started: plan=$PLAN sonnet_only=$SONNET_ONLY ═══"
  log "Streaming claude output → $RUN_LOG (tail -f to watch)"

  if [[ "$SONNET_ONLY" == true ]]; then
    run_flat_loop
  else
    run_hierarchical_loop
  fi
}

main
