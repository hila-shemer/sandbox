#!/bin/bash
# Note: no set -e here — we deliberately invoke commands that exit non-zero
set -uo pipefail

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Set up a stub claude on PATH that exits 0 immediately
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_DIR/claude"
export PATH="$STUB_DIR:$PATH"

SCRIPT="./ralph/ralph.sh"

# Test 1: valid invocation — parser accepts the flags (no "Unknown argument")
out=$(MAX_OUTER=1 MAX_INNER=1 timeout 5s "$SCRIPT" /dev/null 2>&1) && rc=0 || rc=$?
if echo "$out" | grep -q "Unknown argument"; then
  fail "Test 1: valid invocation printed 'Unknown argument'"
else
  pass "Test 1: valid invocation accepted"
fi

# Test 2: --sonnet-only — valid
out=$(MAX_FLAT=1 timeout 5s "$SCRIPT" /dev/null --sonnet-only 2>&1) && rc=0 || rc=$?
if echo "$out" | grep -q "Unknown argument"; then
  fail "Test 2: --sonnet-only printed 'Unknown argument'"
else
  pass "Test 2: --sonnet-only accepted"
fi

# Test 3: --resume — parser accepts it (script may fail later, that's OK)
out=$(MAX_OUTER=1 MAX_INNER=1 timeout 5s "$SCRIPT" /dev/null --resume 2>&1) && rc=0 || rc=$?
if echo "$out" | grep -q "Unknown argument"; then
  fail "Test 3: --resume printed 'Unknown argument'"
else
  pass "Test 3: --resume accepted by parser"
fi

# Test 4: --sonnet-only --resume — must exit 2 with specific message
out=$(timeout 5s "$SCRIPT" /dev/null --sonnet-only --resume 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]] && echo "$out" | grep -q -- "--resume is only supported in hierarchical mode"; then
  pass "Test 4: --sonnet-only --resume exits 2 with correct message"
else
  fail "Test 4: expected exit 2 + message, got exit $rc. Output: $out"
fi

# Test 5: --resume --sonnet-only (order reversed) — same requirement
out=$(timeout 5s "$SCRIPT" /dev/null --resume --sonnet-only 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]] && echo "$out" | grep -q -- "--resume is only supported in hierarchical mode"; then
  pass "Test 5: --resume --sonnet-only exits 2 with correct message"
else
  fail "Test 5: expected exit 2 + message, got exit $rc. Output: $out"
fi

# Test 6: unknown flag — must exit 2 with "Unknown argument: --garbage"
out=$(timeout 5s "$SCRIPT" /dev/null --garbage 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]] && echo "$out" | grep -q "Unknown argument: --garbage"; then
  pass "Test 6: unknown flag exits 2 with 'Unknown argument: --garbage'"
else
  fail "Test 6: expected exit 2 + message, got exit $rc. Output: $out"
fi

# Test 7: no plan argument — must exit non-zero (:? expansion)
"$SCRIPT" 2>/dev/null && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Test 7: no plan exits non-zero ($rc)"
else
  fail "Test 7: expected non-zero exit, got 0"
fi

# ── Phase-based resume tests ─────────────────────────────────────────
# Each test uses an isolated temp git repo to avoid cross-test state leakage.

TDIR=$(mktemp -d)
# Update trap to also clean up TDIR
trap 'rm -rf "$STUB_DIR" "$TDIR"' EXIT INT TERM

# STUBBIN: a separate stub dir we can swap out per-test
STUBBIN=$(mktemp -d)
trap 'rm -rf "$STUB_DIR" "$TDIR" "$STUBBIN"' EXIT INT TERM

# Default stub: exits 0 silently
cat > "$STUBBIN/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUBBIN/claude"

setup_test_dir() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  git commit --allow-empty -q -m "init"
  cd - >/dev/null
}

run_ralph_resume() {
  # Run ralph with --resume from the given dir; capture combined output.
  # Passes RALPH_DIR and MAX_OUTER/MAX_INNER to keep execution bounded.
  local dir="$1"
  shift
  (cd "$dir" && PATH="$STUBBIN:$PATH" RALPH_DIR=/app/ralph MAX_OUTER=1 MAX_INNER=1 timeout 5s /app/ralph/ralph.sh /dev/null --resume "$@" 2>&1)
}

# Test 8: empty git repo, no files → "starting fresh"
setup_test_dir "$TDIR/t8"
out=$(run_ralph_resume "$TDIR/t8") && rc=0 || rc=$?
if echo "$out" | grep -q "starting fresh"; then
  pass "Test 8: empty repo with --resume logs 'starting fresh'"
else
  fail "Test 8: expected 'starting fresh' in output. rc=$rc. Output: $out"
fi

# Test 9: .ralph/phase=idle, no memory files → "clean prior termination"
setup_test_dir "$TDIR/t9"
mkdir -p "$TDIR/t9/.ralph"
echo "idle" > "$TDIR/t9/.ralph/phase"
out=$(run_ralph_resume "$TDIR/t9") && rc=0 || rc=$?
if echo "$out" | grep -q "clean prior termination"; then
  pass "Test 9: phase=idle logs 'clean prior termination'"
else
  fail "Test 9: expected 'clean prior termination'. rc=$rc. Output: $out"
fi

# Test 10: .ralph/phase=planner-pending → "re-running planner"
setup_test_dir "$TDIR/t10"
mkdir -p "$TDIR/t10/.ralph"
echo "planner-pending" > "$TDIR/t10/.ralph/phase"
out=$(run_ralph_resume "$TDIR/t10") && rc=0 || rc=$?
if echo "$out" | grep -q "re-running planner"; then
  pass "Test 10: phase=planner-pending logs 're-running planner'"
else
  fail "Test 10: expected 're-running planner'. rc=$rc. Output: $out"
fi

# Test 11: .ralph/phase=executor-pending, CURRENT_TASK.md with in-progress status
setup_test_dir "$TDIR/t11"
mkdir -p "$TDIR/t11/.ralph"
echo "executor-pending" > "$TDIR/t11/.ralph/phase"
echo "# In Progress" > "$TDIR/t11/CURRENT_TASK.md"
out=$(run_ralph_resume "$TDIR/t11") && rc=0 || rc=$?
if echo "$out" | grep -q "re-entering executor"; then
  pass "Test 11: phase=executor-pending with in-progress CURRENT_TASK.md logs 're-entering executor'"
else
  fail "Test 11: expected 're-entering executor'. rc=$rc. Output: $out"
fi

# Test 12: .ralph/phase=executor-pending, no CURRENT_TASK.md → falls back to classifier
# Use a stub that outputs "RESUME: planner"
cat > "$STUBBIN/claude" <<'EOF'
#!/bin/sh
echo "RESUME: planner"
EOF
chmod +x "$STUBBIN/claude"

setup_test_dir "$TDIR/t12"
mkdir -p "$TDIR/t12/.ralph"
echo "executor-pending" > "$TDIR/t12/.ralph/phase"
out=$(run_ralph_resume "$TDIR/t12") && rc=0 || rc=$?
if echo "$out" | grep -q "falling back to classifier"; then
  pass "Test 12: executor-pending without CURRENT_TASK.md falls back to classifier"
else
  fail "Test 12: expected 'falling back to classifier'. rc=$rc. Output: $out"
fi

# Restore silent stub
cat > "$STUBBIN/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUBBIN/claude"

# Test 13: tracked file with uncommitted change → exit 1, log "uncommitted changes"
setup_test_dir "$TDIR/t13"
echo "hello" > "$TDIR/t13/tracked.txt"
(cd "$TDIR/t13" && git add tracked.txt && git commit -q -m "add file")
echo "modified" > "$TDIR/t13/tracked.txt"
out=$(run_ralph_resume "$TDIR/t13") && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "uncommitted changes"; then
  pass "Test 13: dirty working tree exits 1 with 'uncommitted changes'"
else
  fail "Test 13: expected exit 1 + 'uncommitted changes'. rc=$rc. Output: $out"
fi

# Test 14: CURRENT_TASK.md first line "COMPLETE" → exit 0, log "already complete"
setup_test_dir "$TDIR/t14"
echo "COMPLETE" > "$TDIR/t14/CURRENT_TASK.md"
out=$(run_ralph_resume "$TDIR/t14") && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q "already complete"; then
  pass "Test 14: CURRENT_TASK.md=COMPLETE exits 0 with 'already complete'"
else
  fail "Test 14: expected exit 0 + 'already complete'. rc=$rc. Output: $out"
fi

# Test 15: CURRENT_TASK.md first line "BLOCKED: reason" → exit 1, log "resolve the block"
setup_test_dir "$TDIR/t15"
echo "BLOCKED: some reason" > "$TDIR/t15/CURRENT_TASK.md"
out=$(run_ralph_resume "$TDIR/t15") && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "resolve the block"; then
  pass "Test 15: CURRENT_TASK.md=BLOCKED exits 1 with 'resolve the block'"
else
  fail "Test 15: expected exit 1 + 'resolve the block'. rc=$rc. Output: $out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
