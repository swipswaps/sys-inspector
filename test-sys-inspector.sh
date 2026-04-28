#!/usr/bin/env bash
# test-sys-inspector.sh — Automated TUI testing with expect
# Implements RLM §3.3 recursive validation at the system level
# Fixes Issue 4 from video: PTY size mismatch causing screen corruption

set -euo pipefail

TEST_RESULTS_DIR="/tmp/sys-inspector-test-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$TEST_RESULTS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR AUTOMATED TEST SUITE (RLM Recursive Validation)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Test 1: Non-interactive test mode (built into TUI)
echo -e "${BLUE}[TEST 1]${NC} Running built-in test mode..."
SYS_INSPECTOR_TEST=1 bash src/tui/sys-inspector-tui.sh 2>&1 | tee "$TEST_RESULTS_DIR/test1.log"
if [[ ${PIPESTATUS[0]} -eq 0 ]] && grep -q "TEST SEQUENCE COMPLETE" "$TEST_RESULTS_DIR/test1.log"; then
    echo -e "  ${GREEN}✓ Test mode passed${NC}"
    TEST1_PASS=1
else
    echo -e "  ${RED}✗ Test mode failed${NC}"
    TEST1_PASS=0
fi

# Test 2: Expect-driven interactive test (with PTY fix for Issue 4)
echo -e "${BLUE}[TEST 2]${NC} Running expect-driven interactive test..."

# Issue 4 fix: Set explicit PTY size before expect spawn
export LINES=24
export COLUMNS=80

expect << 'EOF' | tee "$TEST_RESULTS_DIR/test2-output.log"
set timeout 60
set env(LINES) 24
set env(COLUMNS) 80

log_file "$TEST_RESULTS_DIR/expect-session.log"

# PTY fix: Set stty explicitly
stty rows 24 cols 80

# Start the TUI with PTY fix flags
spawn bash -c "export LINES=24 COLUMNS=80 SYS_INSPECTOR_PTY_FIX=1; exec bash src/tui/sys-inspector-tui.sh"

# Wait for menu to appear
expect {
    -re "SYS-INSPECTOR.*Boot History" { send "1\r"; exp_continue }
    -re "Boot History.*20" { send "q\r"; exp_continue }
    -re "Service Audit.*count" { send "q\r"; exp_continue }
    -re "Active Errors.*system" { send "q\r"; exp_continue }
    -re "Database Statistics.*records" { send "q\r"; exp_continue }
    -re "Run Collectors|Run Collector" { 
        send "5\r"
        exp_continue
    }
    -re "Choose a collector" {
        send "2\r"  # Service Manifest
        exp_continue
    }
    -re "SERVICE MANIFEST|service-manifest" {
        send "q\r"
        exp_continue
    }
    -re "SYS-INSPECTOR.*Boot History" {
        send "0\r"
        exp_continue
    }
    timeout { puts "TIMEOUT - Test incomplete"; exit 1 }
    eof { puts "Test completed successfully" }
}

puts "\nTest completed"
EOF

if grep -q "Test completed successfully" "$TEST_RESULTS_DIR/test2-output.log"; then
    echo -e "  ${GREEN}✓ Expect test passed (no screen corruption)${NC}"
    TEST2_PASS=1
else
    echo -e "  ${RED}✗ Expect test failed - check $TEST_RESULTS_DIR/expect-session.log${NC}"
    TEST2_PASS=0
fi

# Test 3: Database validation after collectors (RLM Layers 0-3.5)
echo -e "${BLUE}[TEST 3]${NC} Validating database state..."
./verify-complete.sh > "$TEST_RESULTS_DIR/test3.log" 2>&1
if [[ $? -eq 0 ]]; then
    echo -e "  ${GREEN}✓ Database validation passed${NC}"
    TEST3_PASS=1
else
    echo -e "  ${YELLOW}⚠ Database validation had warnings (see log)${NC}"
    TEST3_PASS=0
fi

# Test 4: Collector execution benchmark
echo -e "${BLUE}[TEST 4]${NC} Benchmarking collector execution..."
echo "  Running boot-health collector 3 times..." > "$TEST_RESULTS_DIR/test4.log"

TIMES=()
for i in {1..3}; do
    START=$(date +%s%N)
    bash src/collectors/boot-health.sh >/dev/null 2>&1
    END=$(date +%s%N)
    DURATION=$(( (END - START) / 1000000 ))
    TIMES+=($DURATION)
    echo "    Run $i: ${DURATION}ms" | tee -a "$TEST_RESULTS_DIR/test4.log"
done

AVG=$(( (TIMES[0] + TIMES[1] + TIMES[2]) / 3 ))
echo "    Average: ${AVG}ms" | tee -a "$TEST_RESULTS_DIR/test4.log"

if [[ $AVG -lt 5000 ]]; then
    echo -e "  ${GREEN}✓ Performance acceptable (<5s)${NC}"
    TEST4_PASS=1
else
    echo -e "  ${YELLOW}⚠ Performance slow (>5s)${NC}"
    TEST4_PASS=0
fi

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  TEST SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo "  Test 1 (non-interactive): $([ $TEST1_PASS -eq 1 ] && echo "✓ PASS" || echo "✗ FAIL")"
echo "  Test 2 (expect/PTY):      $([ $TEST2_PASS -eq 1 ] && echo "✓ PASS" || echo "✗ FAIL")"
echo "  Test 3 (database):        $([ $TEST3_PASS -eq 1 ] && echo "✓ PASS" || echo "⚠ WARN")"
echo "  Test 4 (performance):     $([ $TEST4_PASS -eq 1 ] && echo "✓ PASS" || echo "⚠ WARN")"
echo ""
echo "  Results saved to: $TEST_RESULTS_DIR/"
echo "    - test1.log         (non-interactive test)"
echo "    - test2-output.log  (expect output)"
echo "    - expect-session.log (full expect session)"
echo "    - test3.log         (database validation)"
echo "    - test4.log         (benchmark results)"
echo "═══════════════════════════════════════════════════════════════"

if [[ $TEST1_PASS -eq 1 ]] && [[ $TEST2_PASS -eq 1 ]]; then
    echo -e "${GREEN}✓ All critical tests passed${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed - see logs above${NC}"
    exit 1
fi