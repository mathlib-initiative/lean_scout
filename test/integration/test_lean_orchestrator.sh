#!/usr/bin/env bash
#
# Integration tests for Lean Scout orchestrator CLI
#
# Run from repository root:
#   ./test/integration/test_lean_orchestrator.sh
#
# Or via run_tests script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

# Test helper functions
pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

run_test() {
    local name="$1"
    local cmd="$2"
    local expected_exit="$3"
    local check_pattern="$4"

    # Run command and capture output/exit code
    set +e
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    set -e

    # Check exit code
    if [ "$exit_code" -ne "$expected_exit" ]; then
        fail "$name (expected exit $expected_exit, got $exit_code)"
        return
    fi

    # Check pattern if provided
    if [ -n "$check_pattern" ]; then
        if echo "$output" | grep -q "$check_pattern"; then
            pass "$name"
        else
            fail "$name (pattern '$check_pattern' not found)"
        fi
    else
        pass "$name"
    fi
}

# Determine script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_PROJECT="$REPO_ROOT/test_project"

# Change to test_project directory for tests
cd "$TEST_PROJECT"

echo "=== Lean Orchestrator Integration Tests ==="
echo -e "${YELLOW}Running from: $TEST_PROJECT${NC}"
echo ""

# --- CLI Validation Tests ---
echo "CLI Validation:"

run_test "Missing --command shows error" \
    "lake run scout --parquet --imports Lean" \
    1 "No command specified"

run_test "Missing target shows error" \
    "lake run scout --command types --parquet" \
    1 "No target specified"

run_test "Missing writer shows error" \
    "lake run scout --command types --imports Lean" \
    1 "No writer specified"

run_test "Invalid command shows error" \
    "lake run scout --command nonexistent --parquet --imports Lean" \
    1 "No data extractor found"

echo ""

# --- Target Tests ---
echo "Target Resolution:"

run_test "--imports works" \
    "lake run scout --command types --jsonl --imports LeanScoutTestProject" \
    0 ""

run_test "--library works" \
    "lake run scout --command types --jsonl --parallel 1 --library LeanScoutTestProject" \
    0 ""

echo ""

# --- Output Format Tests ---
echo "Output Formats:"

# Test JSONL outputs valid JSON
set +e
output=$(lake run scout --command types --jsonl --imports LeanScoutTestProject 2>/dev/null | head -1)
if echo "$output" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
    pass "JSONL outputs valid JSON"
else
    fail "JSONL outputs valid JSON"
fi
set -e

# Test parquet creates files
tmpdir=$(mktemp -d)
set +e
lake run scout --command types --parquet --dataDir "$tmpdir" --imports LeanScoutTestProject 2>/dev/null
if ls "$tmpdir"/*.parquet >/dev/null 2>&1; then
    pass "Parquet creates files"
else
    fail "Parquet creates files"
fi
set -e
rm -rf "$tmpdir"

# Test logs go to stderr
set +e
stderr_output=$(lake run scout --command types --jsonl --imports LeanScoutTestProject 2>&1 >/dev/null)
if echo "$stderr_output" | grep -q "\[INFO\]"; then
    pass "Logs go to stderr"
else
    fail "Logs go to stderr"
fi
set -e

echo ""

# --- Parallel Execution Tests ---
echo "Parallel Execution:"

run_test "--parallel option accepted" \
    "lake run scout --command types --jsonl --parallel 2 --imports LeanScoutTestProject" \
    0 ""

# Test multiple tasks with --library
set +e
logs=$(lake run scout --command types --jsonl --parallel 2 --library LeanScoutTestProject 2>&1 >/dev/null)
task_count=$(echo "$logs" | grep -c "Started extractor task" || true)
if [ "$task_count" -ge 2 ]; then
    pass "Multiple tasks started with --library (found $task_count)"
else
    fail "Multiple tasks started with --library (expected >=2, got $task_count)"
fi
set -e

echo ""

# --- Parquet Writer Options Tests ---
echo "Parquet Writer Options:"

# Test --numShards option
tmpdir=$(mktemp -d)
set +e
lake run scout --command types --parquet --dataDir "$tmpdir" --numShards 4 --imports LeanScoutTestProject 2>/dev/null
shard_count=$(ls "$tmpdir"/*.parquet 2>/dev/null | wc -l)
if [ "$shard_count" -le 4 ] && [ "$shard_count" -gt 0 ]; then
    pass "--numShards limits shard count (got $shard_count shards)"
else
    fail "--numShards limits shard count (expected <=4, got $shard_count)"
fi
set -e
rm -rf "$tmpdir"

# Test --batchRows option accepted
tmpdir=$(mktemp -d)
run_test "--batchRows option accepted" \
    "lake run scout --command types --parquet --dataDir '$tmpdir' --batchRows 100 --imports LeanScoutTestProject 2>/dev/null" \
    0 ""
rm -rf "$tmpdir"

echo ""

# --- Summary ---
echo "=== Results ==="
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi

echo ""
echo -e "${GREEN}All integration tests passed!${NC}"
