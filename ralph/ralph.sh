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
#   MAX_FLAT           — max Sonnet iterations in --sonnet-only flat mode
#                        before aborting with nonzero exit (default: 100)
#   REVIEW_INTERVAL    — Opus review every N Sonnet iterations (default: 4)
#   RALPH_LOG          — per-run log of status markers AND every `claude -p`
#                        call's stdout (default: ralph-<timestamp>.log, one
#                        per invocation). Tail in another pane to watch
#                        progress live:
#                          tail -f ralph-YYYYMMDD-HHMMSS.log
#   CLAUDE_FLAGS       — extra flags passed to every `claude` invocation.
#                        Inside the sandbox container this is preset to
#                        "--dangerously-skip-permissions" so tool use is
#                        auto-approved (the container is the permission boundary).
#   RETRY_MAX_ATTEMPTS — total claude attempts per call site, incl. the
#                        first try (default: 8). After exhausting retries
#                        the loop aborts.
#   RETRY_BASE_DELAY   — seconds to wait before the first retry, doubled
#                        on each subsequent failure (default: 30).
#   RETRY_MAX_DELAY    — cap on per-retry backoff in seconds
#                        (default: 900 = 15 min).
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
MAX_FLAT="${MAX_FLAT:-100}"
REVIEW_INTERVAL="${REVIEW_INTERVAL:-4}"
# LOG is the unified per-run log. It receives both status markers from log()
# and the tee'd stdout of every `claude -p` call, so a single `tail -f` gives
# the full narrative. Default is timestamped in main() — override with
# RALPH_LOG if you want to pin the filename (e.g. for an outer wrapper).
LOG="${RALPH_LOG:-}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-8}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-30}"
RETRY_MAX_DELAY="${RETRY_MAX_DELAY:-900}"

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

# Write a header into the per-run log so a `tail -f` watcher can tell which
# claude call's output they're looking at. Called just before each `claude -p`
# invocation.
run_log_header() {
  {
    echo ""
    echo "=== [$(date '+%H:%M:%S')] $* ==="
  } >> "$LOG"
}

status_line() {
  # Normalize the first line of STATUS.md (or the file passed in $1):
  # strip a leading UTF-8 BOM, then whitespace and `#` markdown headers,
  # then uppercase. Tolerates "﻿TASK_DONE", "## TASK_DONE", "  task_done  ",
  # etc. BLOCKED:<reason> still matches a BLOCKED* glob because the prefix
  # is preserved (colon and reason get flattened but that's fine).
  head -n 1 "${1:-STATUS.md}" 2>/dev/null \
    | sed $'s/^\xef\xbb\xbf//' \
    | tr -d '[:space:]#' \
    | tr '[:lower:]' '[:upper:]'
}

git_log_summary() {
  # If we've recorded the HEAD of the previous planner cycle, only show
  # commits since then — this stops us from burning planner context on
  # ancient history in long-running projects. Otherwise fall back to the
  # last 30 commits. The planner (not the reviewer) updates the marker
  # after each cycle; see record_planner_sha().
  local marker=".ralph/last_planner_sha"
  if [[ -f "$marker" ]]; then
    local since
    since=$(cat "$marker" 2>/dev/null || true)
    if [[ -n "$since" ]] && git rev-parse --verify --quiet "${since}^{commit}" >/dev/null 2>&1; then
      local hidden
      hidden=$(git rev-list --count "$since" 2>/dev/null || echo 0)
      git log --oneline "$since..HEAD" 2>/dev/null \
        || echo "(no new commits since last planner cycle)"
      echo "(showing commits since last planner cycle; $hidden earlier commits hidden)"
      return
    fi
  fi
  git log --oneline -30 2>/dev/null || echo "(no commits yet)"
}

# Called at the end of each planner cycle so the next cycle's git_log_summary
# only shows new work. Reviewer must NOT call this — the window should span
# the full planner cycle including any mid-task reviews.
record_planner_sha() {
  mkdir -p .ralph
  git rev-parse HEAD > .ralph/last_planner_sha 2>/dev/null || true
}

test_summary() {
  # Reads whatever run_tests() last wrote to test_results.txt. The script
  # run_tests.sh is maintained by Sonnet as part of each iteration's work
  # (see sonnet_suffix.md — "Test Harness Contract"); ralph drives it via
  # run_tests() below. If Sonnet has not yet created run_tests.sh, the file
  # will contain an explanatory placeholder written by run_tests().
  if [[ -f test_results.txt ]]; then
    tail -20 test_results.txt
  else
    echo "(no test results file found)"
  fi
}

run_tests() {
  # Invoked between Sonnet iterations and before handing back to the planner,
  # so test_results.txt is always fresh when the planner or reviewer reads
  # it next. Non-fatal: broken tests are information for the planner, not a
  # loop abort.
  if [[ -x ./run_tests.sh ]]; then
    log "  Running tests via ./run_tests.sh"
    ./run_tests.sh > test_results.txt 2>&1 || true
  else
    log "  No run_tests.sh yet — executor has not set up test harness"
    echo "(run_tests.sh not present — executor has not set up test harness yet)" > test_results.txt
  fi
}

# Wraps a single `claude -p ...` invocation with retry + exponential backoff
# on non-zero exit. Transient failures (API overload, rate limit, network
# blip) usually clear in minutes; structural failures (bad auth, missing
# model, prompt too large) don't. We can't cheaply distinguish from the CLI
# exit code alone, so we retry uniformly and cap attempts — a broken config
# still fails within an hour or so instead of spinning forever.
#
# Stdin is captured once into a tempfile so each retry replays the same
# prompt. stdout/stderr are tee'd to $LOG exactly as the original inline
# pipelines did.
call_claude() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"

  local attempt=0
  local delay="$RETRY_BASE_DELAY"
  local rc=0

  while :; do
    attempt=$((attempt + 1))
    if claude "$@" < "$tmp" 2>>"$LOG" | tee -a "$LOG"; then
      rc=0
      break
    fi
    if (( attempt >= RETRY_MAX_ATTEMPTS )); then
      log "  claude failed on attempt $attempt/$RETRY_MAX_ATTEMPTS — retries exhausted, aborting"
      rc=1
      break
    fi
    log "  claude failed on attempt $attempt/$RETRY_MAX_ATTEMPTS — sleeping ${delay}s before retry"
    sleep "$delay"
    delay=$(( delay * 2 ))
    (( delay > RETRY_MAX_DELAY )) && delay=$RETRY_MAX_DELAY
  done

  rm -f "$tmp"
  return "$rc"
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
  } | call_claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL"

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
      | call_claude -p $CLAUDE_FLAGS --model "$SONNET_MODEL"

    # Refresh test_results.txt so any Opus reviewer triggered this iteration
    # (periodic or BLOCKED-unblock) sees current test state.
    run_tests

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
  while (( iteration < MAX_FLAT )); do
    iteration=$((iteration + 1))
    log "Iteration $iteration / $MAX_FLAT"
    run_log_header "Sonnet flat iteration $iteration / $MAX_FLAT"

    cat "$SONNET_PREFIX" "$PLAN" "$SONNET_SUFFIX" \
      | call_claude -p $CLAUDE_FLAGS --model "$SONNET_MODEL"

    local status
    status=$(status_line)

    if [[ "$status" == "DONE" ]]; then
      log "✓ Complete after $iteration iteration(s)"
      return 0
    elif [[ "$status" == BLOCKED* ]]; then
      log "✗ $status (after $iteration iterations)"
      return 1
    fi

    run_tests
  done

  log "✗ Hit MAX_FLAT cap ($MAX_FLAT) without DONE/BLOCKED — aborting"
  return 1
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
    } | call_claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL"

    # Record HEAD right after the planner call so the next planner cycle's
    # git_log_summary shows only the work Sonnet/reviewer did between planner
    # invocations. Reviewer never touches this marker.
    record_planner_sha

    # Check what Opus wrote (normalized: tolerates "## COMPLETE", whitespace,
    # lowercase, BOMs, etc.)
    local task_status
    task_status=$(status_line CURRENT_TASK.md)

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

  # One log per run, created here so status markers and every claude call's
  # stdout append to the same timestamped file. Tail it in another pane:
  #   tail -f ralph-YYYYMMDD-HHMMSS.log
  if [[ -z "$LOG" ]]; then
    LOG="ralph-$(date +%Y%m%d-%H%M%S).log"
  fi
  : > "$LOG"

  check_prompt_files
  ensure_git

  log "═══ Ralph started: plan=$PLAN sonnet_only=$SONNET_ONLY ═══"
  log "Log file: $LOG (tail -f to watch)"

  if [[ "$SONNET_ONLY" == true ]]; then
    run_flat_loop
  else
    run_hierarchical_loop
  fi
}

main
