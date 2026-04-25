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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
