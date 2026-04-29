#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# ralph.sh — autonomous implementation loop
#
# Three-role architecture:
#   Planner  (Opus)  : decomposes plan into task slices
#   Executor (Sonnet): implements the current task slice
#   Reviewer (Opus)  : periodic outside-eye review, catches drift
#
# The reviewer is called in two places, both periodic:
#   - mid-task (inside the executor's inner loop), to catch executor drift
#     within a single task slice
#   - outer-cycle (between planner cycles), to catch planner drift
#     across a window of planner cycles
#
# Usage:
#   ./ralph.sh <implementation_plan.md>
#   ./ralph.sh <implementation_plan.md> --sonnet-only   # flat loop, no reviewer
#   ./ralph.sh <implementation_plan.md> --resume        # resume from last checkpoint
#
# Environment variables:
#   RALPH_DIR          — directory containing prompt files (default: script dir)
#   PLANNER_MODEL      — model for the planner (default: opus)
#   SONNET_MODEL       — model for execution (default: sonnet)
#   OPUS_MODEL         — model for the reviewer (default: opus)
#   MAX_INNER          — max Sonnet iterations per task (default: 8)
#   MAX_OUTER          — max planner cycles (default: 50)
#   MAX_FLAT           — max Sonnet iterations in --sonnet-only flat mode
#                        before aborting with nonzero exit (default: 100)
#   REVIEW_INTERVAL    — reviewer call every N executor iterations inside
#                        a single task slice (default: 4, 0=disable).
#                        Rarely fires in practice — Sonnet usually finishes
#                        a slice in 1 iteration — but kicks in if it stalls.
#   OUTER_REVIEW_INTERVAL — reviewer call every N planner cycles
#                        (default: 3, 0=disable). This is the main line of
#                        defense against the Sonnet planner silently drifting.
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
#                        first try (default: 30). With the default 30s base
#                        and 900s cap, 30 attempts covers ~6h30m of sleep —
#                        enough to ride out a 5-hour quota window reset.
#                        After exhausting retries the loop aborts.
#   RETRY_BASE_DELAY   — seconds to wait before the first retry, doubled
#                        on each subsequent failure (default: 30).
#   RETRY_MAX_DELAY    — cap on per-retry backoff in seconds
#                        (default: 900 = 15 min).
#   TEST_TIMEOUT       — seconds before ./run_tests.sh is killed (default: 900).
#                        Set to 0 to disable.
#   CLAUDE_TIMEOUT     — seconds before a single `claude -p` call is killed and
#                        retried (default: 5400). Set to 0 to disable.
# ──────────────────────────────────────────────────────────────────────

PLAN="${1:?Usage: $0 <implementation_plan.md> [--sonnet-only] [--resume]}"
shift
SONNET_ONLY=false
RESUME=false
for arg in "$@"; do
  case "$arg" in
    --sonnet-only) SONNET_ONLY=true ;;
    --resume)      RESUME=true ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: $0 <implementation_plan.md> [--sonnet-only] [--resume]" >&2
       exit 2 ;;
  esac
done
if $RESUME && $SONNET_ONLY; then
  echo "--resume is only supported in hierarchical mode" >&2
  exit 2
fi

# Resolve prompt directory (where the .md prompt files live)
RALPH_DIR="${RALPH_DIR:-$(cd "$(dirname "$0")" && pwd)}"

PLANNER_MODEL="${PLANNER_MODEL:-opus}"
SONNET_MODEL="${SONNET_MODEL:-sonnet}"
OPUS_MODEL="${OPUS_MODEL:-opus}"
MAX_INNER="${MAX_INNER:-8}"
MAX_OUTER="${MAX_OUTER:-50}"
MAX_FLAT="${MAX_FLAT:-100}"
REVIEW_INTERVAL="${REVIEW_INTERVAL:-4}"
OUTER_REVIEW_INTERVAL="${OUTER_REVIEW_INTERVAL:-3}"
# LOG is the unified per-run log. It receives both status markers from log()
# and the tee'd stdout of every `claude -p` call, so a single `tail -f` gives
# the full narrative. Default is timestamped in main() — override with
# RALPH_LOG if you want to pin the filename (e.g. for an outer wrapper).
LOG="${RALPH_LOG:-}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-30}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-30}"
RETRY_MAX_DELAY="${RETRY_MAX_DELAY:-900}"
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-5400}"

# The installed `claude` CLI supports --output-format stream-json (with
# --print --verbose), but that emits JSON-wrapped chunks which are not ideal
# for human `tail -f`. We stick with the default text output; stdout already
# streams as Claude generates it.

# Prompt files
SONNET_PREFIX="$RALPH_DIR/sonnet_prefix.md"
SONNET_SUFFIX="$RALPH_DIR/sonnet_suffix.md"
PLANNER_PROMPT="$RALPH_DIR/planner.md"
REVIEWER_PROMPT="$RALPH_DIR/reviewer.md"
RESUME_PROMPT="$RALPH_DIR/resume.md"
EXIT_GATE_PROMPT="$RALPH_DIR/exit_gate.md"
_RESUME_PHASE=""  # set by decide_resume_phase

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
  #
  # Trailing `|| true` keeps this function return-0 even when the target
  # file is missing: `head -n 1 /nonexistent` exits 1, and with pipefail
  # the whole pipe would inherit that. Callers use `x=$(status_line ...)`
  # in plain assignments, and under `set -e` a failing command substitution
  # would abort the whole run before we ever see the empty string.
  { head -n 1 "${1:-STATUS.md}" 2>/dev/null \
      | sed $'s/^\xef\xbb\xbf//' \
      | tr -d '[:space:]#' \
      | tr '[:lower:]' '[:upper:]'; } || true
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
    if (( TEST_TIMEOUT > 0 )); then
      log "  Running tests via ./run_tests.sh (timeout: ${TEST_TIMEOUT}s)"
      local rc=0
      timeout "$TEST_TIMEOUT" ./run_tests.sh > test_results.txt 2>&1 || rc=$?
      if (( rc == 124 )); then
        log "  Tests timed out after ${TEST_TIMEOUT}s"
        printf '(run_tests.sh timed out after %ss)\n' "$TEST_TIMEOUT" >> test_results.txt
      fi
    else
      log "  Running tests via ./run_tests.sh"
      ./run_tests.sh > test_results.txt 2>&1 || true
    fi
  else
    log "  No run_tests.sh yet — executor has not set up test harness"
    echo "(run_tests.sh not present — executor has not set up test harness yet)" > test_results.txt
  fi
}

# Wraps a single `claude -p ...` invocation with retry + exponential backoff
# on non-zero exit. Transient failures (API overload, network blip) clear in
# minutes; subscription quota exhaustion clears on the 5-hour window reset;
# structural failures (bad auth, missing model, prompt too large) don't clear
# at all. We can't cheaply distinguish from the CLI exit code alone, so we
# retry uniformly with the 900s cap — at 15 min per retry a broken config is
# obviously stuck in the log, just bounded (~6h30m at the default 30 attempts)
# instead of spinning forever.
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
    local call_rc=0
    if (( CLAUDE_TIMEOUT > 0 )); then
      timeout "$CLAUDE_TIMEOUT" claude "$@" < "$tmp" 2>>"$LOG" | tee -a "$LOG" || call_rc=$?
    else
      claude "$@" < "$tmp" 2>>"$LOG" | tee -a "$LOG" || call_rc=$?
    fi
    if (( call_rc == 0 )); then
      rc=0
      break
    fi
    if (( attempt >= RETRY_MAX_ATTEMPTS )); then
      log "  claude failed on attempt $attempt/$RETRY_MAX_ATTEMPTS — retries exhausted, aborting"
      rc=1
      break
    fi
    if (( CLAUDE_TIMEOUT > 0 && call_rc == 124 )); then
      log "  claude timed out after ${CLAUDE_TIMEOUT}s on attempt $attempt/$RETRY_MAX_ATTEMPTS — sleeping ${delay}s before retry"
    else
      log "  claude failed on attempt $attempt/$RETRY_MAX_ATTEMPTS — sleeping ${delay}s before retry"
    fi
    sleep "$delay"
    delay=$(( delay * 2 ))
    (( delay > RETRY_MAX_DELAY )) && delay=$RETRY_MAX_DELAY
  done

  rm -f "$tmp"
  return "$rc"
}

# Sanity-check that the planner/executor/reviewer haven't created memory
# files in a subdirectory. ralph.sh only reads them from CWD, so a misplaced
# copy silently breaks the loop — the harness keeps running against stale
# state. Called after every `claude -p` call that can write these files.
#
# Aborts the run with a clear message if a stray copy is found. False
# positives (e.g., a deliberate `.notes/STATUS.md` unrelated to ralph) are
# rare enough that a hard fail is better than silent drift; if you hit one,
# rename the offending file.
check_memory_files_location() {
  local stray
  # `|| true` guards against find itself exiting non-zero (permission errors
  # on a pruned subtree, etc.) — we only care about what landed on stdout.
  stray=$(find . -path ./.git -prune -o \
      \( -name CURRENT_TASK.md -o -name STATUS.md \
      -o -name DECISIONS.md -o -name PROBLEMS.md \) \
      -not -path './CURRENT_TASK.md' \
      -not -path './STATUS.md' \
      -not -path './DECISIONS.md' \
      -not -path './PROBLEMS.md' \
      -print 2>/dev/null || true)
  if [[ -n "$stray" ]]; then
    log "✗ Memory file(s) placed outside repo root — aborting:"
    while IFS= read -r f; do
      log "    $f"
    done <<< "$stray"
    log "  These files must live at the repo root (CWD). Move or delete them and re-run."
    exit 1
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
    for f in "$SONNET_PREFIX" "$SONNET_SUFFIX" "$PLANNER_PROMPT" "$REVIEWER_PROMPT" "$EXIT_GATE_PROMPT"; do
      [[ -f "$f" ]] || missing+=("$f")
    done
    if [[ "$RESUME" == true ]]; then
      [[ -f "$RESUME_PROMPT" ]] || missing+=("$RESUME_PROMPT")
    fi
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

# ── Reviewer (Opus, two modes) ───────────────────────────────────────

# Mode A: called mid-task inside the executor's inner loop.
run_opus_review() {
  log "  >> Opus review (mid-task)"
  run_log_header "Opus reviewer (mid-task)"

  {
    cat "$REVIEWER_PROMPT"
    echo ""
    echo "## Review Mode: Mid-Task"
    echo ""
    echo "You are inside the executor's inner loop. Scope is the single in-flight"
    echo "task described below. See \"Mode A\" in the prompt above for guidance."
    echo ""
    echo "## Current Task Being Executed"
    echo ""
    cat CURRENT_TASK.md 2>/dev/null || echo "(no current task)"
    echo ""
    echo "---"
    memory_context
  } | call_claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL"

  check_memory_files_location

  # Reviewer may have committed a small fix (see reviewer.md §4).
  # Refresh test_results.txt so the next consumer — Sonnet's next iteration
  # or the outer planner cycle — sees the post-review test state, not the
  # pre-review snapshot Sonnet handed in.
  run_tests

  log "  << Opus review complete"
}

# Git log scoped to the window since the last outer-cycle review.
# Falls back to the last 60 commits if no marker exists yet (first review).
outer_git_log_summary() {
  local marker=".ralph/last_outer_review_sha"
  if [[ -f "$marker" ]]; then
    local since
    since=$(cat "$marker" 2>/dev/null || true)
    if [[ -n "$since" ]] && git rev-parse --verify --quiet "${since}^{commit}" >/dev/null 2>&1; then
      git log --oneline "$since..HEAD" 2>/dev/null \
        || echo "(no new commits since last outer review)"
      return
    fi
  fi
  git log --oneline -60 2>/dev/null || echo "(no commits yet)"
}

record_outer_review_sha() {
  mkdir -p .ralph
  git rev-parse HEAD > .ralph/last_outer_review_sha 2>/dev/null || true
}

# Phase marker. Written before each phase begins so a crash mid-phase
# leaves the marker pointing at the in-flight phase, which is correctly
# the phase to re-enter on --resume.
#
# Allowed values (keep in sync with decide_resume_phase and README):
#   planner-pending   — about to run, or running, the planner call
#   executor-pending  — planner finished, executor not yet started/done
#   between-cycles    — executor returned, about to run outer review or
#                       the next planner cycle
#   idle              — clean termination (COMPLETE/DONE/BLOCKED/MAX_OUTER)
set_phase() {
  mkdir -p .ralph
  printf '%s\n' "$1" > .ralph/phase
}

clear_phase() {
  set_phase idle
}

# Sets RESUME_VERDICT (planner|executor|abort|unparseable) and
# RESUME_REASON (for abort/unparseable).
classify_resume() {
  log "  >> Opus resume classifier"
  run_log_header "Opus resume classifier"

  local out
  out=$(mktemp)

  {
    cat "$RESUME_PROMPT"
    echo ""
    echo "---"
    memory_context
  } | call_claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL" | tee "$out"

  local verdict_line
  verdict_line=$(grep -m1 -E '^RESUME:[[:space:]]' "$out" || true)
  rm -f "$out"

  if [[ -z "$verdict_line" ]]; then
    RESUME_VERDICT=unparseable
    RESUME_REASON="no RESUME: line found in classifier output"
    return
  fi

  local rest tok
  rest="${verdict_line#RESUME:}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # ltrim
  tok="${rest%%[[:space:]]*}"
  case "$tok" in
    planner|executor)
      RESUME_VERDICT="$tok"
      RESUME_REASON="" ;;
    abort)
      RESUME_VERDICT=abort
      RESUME_REASON="${rest#abort}"
      RESUME_REASON="${RESUME_REASON#"${RESUME_REASON%%[![:space:]]*}"}"
      [[ -z "$RESUME_REASON" ]] && RESUME_REASON="(no reason given)" ;;
    *)
      RESUME_VERDICT=unparseable
      RESUME_REASON="unrecognized verdict token: $tok" ;;
  esac
}

# Sets _RESUME_PHASE to: fresh | planner | executor
# May exit 0 (project already complete) or exit 1 (blocked/inconsistent/dirty).
decide_resume_phase() {
  # 1. Pre-resume git check: working tree must be clean of tracked changes.
  local dirty
  dirty=$(git status --porcelain --untracked-files=no)
  if [[ -n "$dirty" ]]; then
    log "✗ --resume aborted: working tree has uncommitted changes:"
    while IFS= read -r line; do log "    $line"; done <<< "$dirty"
    log "  Commit or stash these changes before re-running with --resume."
    exit 1
  fi

  # 2. Terminal task short-circuit.
  if [[ -f CURRENT_TASK.md ]]; then
    local task_status
    task_status=$(status_line CURRENT_TASK.md)
    if [[ "$task_status" == COMPLETE* ]]; then
      log "✓ --resume: CURRENT_TASK.md is COMPLETE — project already complete"
      clear_phase
      exit 0
    elif [[ "$task_status" == BLOCKED* ]]; then
      log "✗ --resume: CURRENT_TASK.md is BLOCKED — resolve the block then re-run"
      clear_phase
      exit 1
    fi
  fi

  # 3. Fresh-state shortcut: no marker AND no memory files → start fresh.
  if [[ ! -f .ralph/phase \
        && ! -f CURRENT_TASK.md \
        && ! -f STATUS.md \
        && ! -f DECISIONS.md \
        && ! -f PROBLEMS.md ]]; then
    log "--resume: no resume state found, starting fresh"
    _RESUME_PHASE=fresh; return
  fi

  # 4. Trust the marker when present and consistent.
  if [[ -f .ralph/phase ]]; then
    local phase
    phase=$(<.ralph/phase)
    case "$phase" in
      planner-pending)
        log "--resume: phase=planner-pending → re-running planner"
        _RESUME_PHASE=planner; return ;;
      executor-pending)
        if [[ -f CURRENT_TASK.md ]]; then
          local s; s=$(status_line CURRENT_TASK.md)
          if [[ "$s" != COMPLETE* && "$s" != BLOCKED* ]]; then
            log "--resume: phase=executor-pending → re-entering executor"
            _RESUME_PHASE=executor; return
          fi
        fi
        log "--resume: phase=executor-pending but CURRENT_TASK.md inconsistent — falling back to classifier" ;;
      between-cycles)
        if [[ -f STATUS.md ]]; then
          log "--resume: phase=between-cycles → starting next planner cycle"
          _RESUME_PHASE=planner; return
        fi
        log "--resume: phase=between-cycles but STATUS.md missing — falling back to classifier" ;;
      idle)
        log "--resume: phase=idle (clean prior termination) → starting fresh planner cycle"
        _RESUME_PHASE=planner; return ;;
      *)
        log "--resume: unrecognized phase=$phase — falling back to classifier" ;;
    esac
  fi

  # 5. Fallback: ask Opus.
  classify_resume
  case "$RESUME_VERDICT" in
    planner|executor) _RESUME_PHASE="$RESUME_VERDICT"; return ;;
    abort)
      log "✗ --resume aborted by classifier: $RESUME_REASON"
      exit 1 ;;
    *)
      log "✗ --resume aborted: classifier produced unparseable output ($RESUME_REASON)"
      exit 1 ;;
  esac
}

# Mode B: called between planner cycles, every OUTER_REVIEW_INTERVAL cycles.
# Scope is the span of planner cycles since the last outer review, not a
# single task. This is the main line of defense against a cheaper Sonnet
# planner silently drifting off-course — Opus reads the git log and memory
# files for that window and leaves corrections in STATUS/DECISIONS/PROBLEMS
# for the next planner cycle to pick up.
run_opus_outer_review() {
  local cycles_since="$1"
  log "  >> Opus review (outer-cycle, last $cycles_since planner cycle(s))"
  run_log_header "Opus reviewer (outer-cycle)"

  {
    cat "$REVIEWER_PROMPT"
    echo ""
    echo "## Review Mode: Outer-Cycle"
    echo ""
    echo "You are being called between planner cycles. Scope is the last"
    echo "$cycles_since planner cycle(s) of work — not a single in-flight task."
    echo "See \"Mode B\" in the prompt above for guidance."
    echo ""
    echo "### Commits since last outer review"
    echo '```'
    outer_git_log_summary
    echo '```'
    echo ""
    echo "---"
    memory_context
  } | call_claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL"

  check_memory_files_location

  record_outer_review_sha
  run_tests

  log "  << Opus outer-cycle review complete"
}

# ── Exit gate (Opus, terminal-status verification) ──────────────────
#
# Called whenever the planner or executor claims a terminal status (DONE,
# COMPLETE, or BLOCKED). Verifies the claim against the actual project state
# before the loop exits. On rejection, the gate is expected to have left
# STATUS.md (and CURRENT_TASK.md if needed) in a non-terminal state so the
# next planner cycle can continue. Returns 0 on CONFIRMED, 1 on REJECTED.
# An unparseable response (no GATE: line) is treated as CONFIRMED with a
# warning — the gate model behavior should be reliable; treating silence as
# REJECTED risks an infinite loop.

run_exit_gate() {
  local claimed_status="$1"
  log "  >> Exit gate (claimed: $claimed_status)"
  run_log_header "Exit gate (claimed: $claimed_status)"

  local out
  out=$(mktemp)

  {
    cat "$EXIT_GATE_PROMPT"
    echo ""
    echo "## Claimed Terminal Status: $claimed_status"
    echo ""
    echo "---"
    memory_context
    echo ""
    echo "## Full Implementation Plan"
    echo ""
    cat "$PLAN"
  } | call_claude -p $CLAUDE_FLAGS --model "$OPUS_MODEL" | tee "$out"

  check_memory_files_location
  run_tests

  local gate_line
  gate_line=$(grep -m1 -E '^GATE:[[:space:]]' "$out" || true)
  rm -f "$out"

  if [[ -z "$gate_line" ]]; then
    log "  << Exit gate: no GATE: line found — treating as CONFIRMED"
    return 0
  fi

  if [[ "$gate_line" == *CONFIRMED* ]]; then
    log "  << Exit gate: CONFIRMED"
    return 0
  else
    log "  << Exit gate: REJECTED — loop continues"
    return 1
  fi
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

    check_memory_files_location

    # Refresh test_results.txt so any Opus reviewer triggered this iteration
    # (periodic or BLOCKED-unblock) sees current test state.
    run_tests

    local status
    status=$(status_line)

    if [[ "$status" == TASK_DONE* || "$status" == DONE* ]]; then
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

    check_memory_files_location

    local status
    status=$(status_line)

    if [[ "$status" == DONE* ]]; then
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

# ── Main: hierarchical loop with planner + periodic reviewer ─────────

run_hierarchical_loop() {
  local resume_action="${1:-fresh}"
  local skip_planner_first=false
  [[ "$resume_action" == "executor" ]] && skip_planner_first=true

  local outer=0

  while (( outer < MAX_OUTER )); do
    outer=$((outer + 1))

    if [[ "$skip_planner_first" == true ]] && (( outer == 1 )); then
      log "=== Resume: skipping planner, executing existing CURRENT_TASK.md ==="
      run_log_header "Resume (executor re-entry)"
      skip_planner_first=false
    else
      log "=== Planner cycle $outer ==="
      run_log_header "Planner cycle $outer"

      set_phase planner-pending

      # Build planner context
      {
        cat "$PLANNER_PROMPT"
        echo ""
        echo "## Full Implementation Plan"
        echo ""
        cat "$PLAN"
        echo ""
        echo "---"
        memory_context
      } | call_claude -p $CLAUDE_FLAGS --model "$PLANNER_MODEL"

      check_memory_files_location

      # Record HEAD right after the planner call so the next planner cycle's
      # git_log_summary shows only the work the executor/reviewer did between
      # planner invocations. Reviewer never touches this marker.
      record_planner_sha

      # Check what the planner wrote (normalized: tolerates "## COMPLETE",
      # whitespace, lowercase, BOMs, etc.)
      local task_status
      task_status=$(status_line CURRENT_TASK.md)

      if [[ "$task_status" == COMPLETE* ]]; then
        log "  Planner declares project complete — running exit gate"
        if run_exit_gate "COMPLETE"; then
          log "✓ Exit gate confirmed: project complete after $outer planning cycle(s)"
          clear_phase
          return 0
        fi
        log "  Exit gate rejected COMPLETE — continuing loop"
        continue
      elif [[ "$task_status" == BLOCKED* ]]; then
        log "  Planner blocked: $task_status — running exit gate"
        if run_exit_gate "BLOCKED"; then
          log "✗ Exit gate confirmed block"
          clear_phase
          return 1
        fi
        log "  Exit gate rejected BLOCKED — continuing loop"
        continue
      fi
    fi

    set_phase executor-pending

    # Run Sonnet on the current task (with periodic mid-task reviews).
    # Non-zero return (BLOCKED after review, or MAX_INNER exhausted) is
    # expected — the planner picks up on the next cycle. Without `|| true`,
    # `set -e` would abort the whole run here.
    run_sonnet CURRENT_TASK.md || true

    set_phase between-cycles

    # If Sonnet declared the whole project DONE
    if [[ "$(status_line)" == DONE* ]]; then
      log "  Sonnet declares full project complete — running exit gate"
      if run_exit_gate "DONE"; then
        log "✓ Exit gate confirmed: project complete"
        clear_phase
        return 0
      fi
      log "  Exit gate rejected DONE — continuing loop"
      continue
    fi

    # Periodic outer-cycle review: every OUTER_REVIEW_INTERVAL planner cycles,
    # call Opus as a stronger outside eye. Defends against a cheaper Sonnet
    # planner silently drifting across multiple cycles. 0 disables.
    if (( OUTER_REVIEW_INTERVAL > 0 && outer % OUTER_REVIEW_INTERVAL == 0 )); then
      run_opus_outer_review "$OUTER_REVIEW_INTERVAL"
    fi

    # Continue to next planner cycle regardless —
    # planner will review the state and decide what's next
  done

  log "✗ Hit max planning cycles ($MAX_OUTER)"
  clear_phase
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

  local resume_action=fresh
  if [[ "$RESUME" == true ]]; then
    decide_resume_phase
    resume_action="$_RESUME_PHASE"
  fi

  log "═══ Ralph started: plan=$PLAN sonnet_only=$SONNET_ONLY resume_action=$resume_action ═══"
  log "Log file: $LOG (tail -f to watch)"

  if [[ "$SONNET_ONLY" == true ]]; then
    run_flat_loop
  else
    run_hierarchical_loop "$resume_action"
  fi
}

main
