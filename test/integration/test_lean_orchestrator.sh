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
    if [ -n "$2" ]; then
        echo -e "${YELLOW}  Output:${NC}"
        echo "$2" | head -20 | sed 's/^/    /'
    fi
    FAILED=$((FAILED + 1))
}

run_test() {
    local name="$1"
    local cmd="$2"
    local expected_exit="$3"
    local check_pattern="$4"

    set +e
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    set -e

    if [ "$exit_code" -ne "$expected_exit" ]; then
        fail "$name (expected exit $expected_exit, got $exit_code)" "$output"
        return
    fi

    if [ -n "$check_pattern" ]; then
        if echo "$output" | grep -q "$check_pattern"; then
            pass "$name"
        else
            fail "$name (pattern '$check_pattern' not found)" "$output"
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

run_test "Invalid --parallel value shows error" \
    "lake run scout --command types --jsonl --parallel abc --imports Lean" \
    1 "Invalid value for --parallel"

run_test "Invalid --numShards value shows error" \
    "lake run scout --command types --jsonl --numShards xyz --imports Lean" \
    1 "Invalid value for --numShards"

run_test "Both --parquet and --jsonl shows error" \
    "lake run scout --command types --parquet --jsonl --imports Lean" \
    1 "Cannot specify both --parquet and --jsonl"

run_test "Multiple targets shows error" \
    "lake run scout --command types --jsonl --library Foo --imports Lean" \
    1 "Cannot specify multiple targets"

echo ""

# --- Target Tests ---
echo "Target Resolution:"

run_test "--imports works" \
    "lake run scout --command types --jsonl --imports LeanScoutTestProject" \
    0 ""

run_test "--library works" \
    "lake run scout --command tactics --jsonl --parallel 1 --library LeanScoutTestProject" \
    0 ""

run_test "--library with invalid name shows error" \
    "lake run scout --command tactics --jsonl --library NonexistentLibrary" \
    1 "lake query failed"

echo ""

# --- Output Format Tests ---
echo "Output Formats:"

set +e
output=$(lake run scout --command types --jsonl --imports LeanScoutTestProject 2>/dev/null | head -1)
if echo "$output" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
    pass "JSONL outputs valid JSON"
else
    full_output=$(lake run scout --command types --jsonl --imports LeanScoutTestProject 2>&1 | head -20)
    fail "JSONL outputs valid JSON" "$full_output"
fi
set -e

tmpdir=$(mktemp -d)
set +e
parquet_output=$(lake run scout --command types --parquet --dataDir "$tmpdir" --imports LeanScoutTestProject 2>&1)
if ls "$tmpdir"/*.parquet >/dev/null 2>&1; then
    pass "Parquet creates files"
else
    fail "Parquet creates files" "$parquet_output"
fi
set -e
rm -rf "$tmpdir"

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

set +e
logs=$(lake run scout --command tactics --jsonl --parallel 2 --library LeanScoutTestProject 2>&1 >/dev/null)
task_count=$(echo "$logs" | grep -c "Started extractor task" || true)
if [ "$task_count" -ge 2 ]; then
    pass "Multiple tasks started with --library (found $task_count)"
else
    fail "Multiple tasks started with --library (expected >=2, got $task_count)" "$logs"
fi
set -e

echo ""

# --- Strict Failure Behavior Tests ---
echo "Strict Failure Behavior:"

bad_syntax=$(mktemp --suffix=.lean)
cat > "$bad_syntax" <<'EOF'
import Init

theorem bad : True := by
  (
EOF

syntax_stdout=$(mktemp)
syntax_stderr=$(mktemp)
set +e
lake run scout --command tactics --jsonl --parallel 1 --read "$bad_syntax" >"$syntax_stdout" 2>"$syntax_stderr"
syntax_exit=$?
set -e
if [ "$syntax_exit" -eq 1 ] && [ ! -s "$syntax_stdout" ]; then
    pass "Syntax errors fail tactics extraction with no JSON output"
else
    fail "Syntax errors fail tactics extraction with no JSON output" "$(cat "$syntax_stderr"; echo; cat "$syntax_stdout")"
fi
rm -f "$bad_syntax" "$syntax_stdout" "$syntax_stderr"

bad_type=$(mktemp --suffix=.lean)
cat > "$bad_type" <<'EOF'
import Init

theorem bad : True := by
  exact 1
EOF

type_stdout=$(mktemp)
type_stderr=$(mktemp)
set +e
lake run scout --command tactics --jsonl --parallel 1 --read "$bad_type" >"$type_stdout" 2>"$type_stderr"
type_exit=$?
set -e
if [ "$type_exit" -eq 1 ] && [ ! -s "$type_stdout" ]; then
    pass "Type errors fail tactics extraction with no JSON output"
else
    fail "Type errors fail tactics extraction with no JSON output" "$(cat "$type_stderr"; echo; cat "$type_stdout")"
fi
rm -f "$bad_type" "$type_stdout" "$type_stderr"

missing_file="/tmp/lean_scout_missing_$$.lean"
set +e
logs=$(lake run scout --command tactics --jsonl --parallel 1 --read "$missing_file" LeanScoutTestProject/Basic.lean 2>&1 >/dev/null)
exit_code=$?
task_count=$(echo "$logs" | grep -c "Started extractor task" || true)
set -e
if [ "$exit_code" -eq 1 ] && [ "$task_count" -eq 1 ]; then
    pass "Fail-fast stops later --read targets after first failure"
else
    fail "Fail-fast stops later --read targets after first failure" "$logs"
fi

set +e
logs=$(lake run scout --command tactics --jsonl --parallel 2 --read "$missing_file" LeanScoutTestProject/Basic.lean LeanScoutTestProject/Lists.lean 2>&1 >/dev/null)
exit_code=$?
task_count=$(echo "$logs" | grep -c "Started extractor task" || true)
set -e
if [ "$exit_code" -eq 1 ] && [ "$task_count" -le 2 ]; then
    pass "Fail-fast with --parallel 2 does not launch targets beyond active workers"
else
    fail "Fail-fast with --parallel 2 does not launch targets beyond active workers" "$logs"
fi

set +e
logs=$(lake run scout --command types --jsonl --library LeanScoutTestProject 2>&1 >/dev/null)
exit_code=$?
task_count=$(echo "$logs" | grep -c "Started extractor task" || true)
set -e
if [ "$exit_code" -eq 1 ] && [ "$task_count" -eq 1 ]; then
    pass "Unsupported multi-target extraction stops after first failure"
else
    fail "Unsupported multi-target extraction stops after first failure" "$logs"
fi

echo ""

# --- Config Validation Tests ---
echo "Config Validation:"

run_test "types rejects wrong config type" \
    "lake run scout --config '{\"filter\":\"notbool\"}' --command types --jsonl --imports LeanScoutTestProject" \
    1 "Invalid config"

run_test "const_dep rejects wrong taskLimit type" \
    "lake run scout --config '{\"taskLimit\":\"notnat\"}' --command const_dep --jsonl --imports LeanScoutTestProject" \
    1 "Invalid config"

run_test "tactics rejects unknown config fields" \
    "lake run scout --config '{\"unknown\":true}' --command tactics --jsonl --read LeanScoutTestProject/Basic.lean" \
    1 "Invalid config"

echo ""

# --- Parquet Failure Handling Tests ---
echo "Parquet Failure Handling:"

tmpdir=$(mktemp -d)
set +e
parquet_output=$(lake run scout --command tactics --parquet --dataDir "$tmpdir" --parallel 1 --read "$missing_file" LeanScoutTestProject/Basic.lean 2>&1)
exit_code=$?
set -e
if [ "$exit_code" -eq 1 ] && [ -d "$tmpdir" ] && [ -z "$(find "$tmpdir" -mindepth 1 -print -quit)" ]; then
    pass "Parquet cleanup removes partial output after failure"
else
    fail "Parquet cleanup removes partial output after failure" "$parquet_output"
fi
rm -rf "$tmpdir"

bad_syntax=$(mktemp --suffix=.lean)
cat > "$bad_syntax" <<'EOF'
import Init

theorem bad : True := by
  (
EOF

tmpdir=$(mktemp -d)
set +e
parquet_output=$(lake run scout --command tactics --parquet --dataDir "$tmpdir" --parallel 1 --read "$bad_syntax" 2>&1)
exit_code=$?
set -e
if [ "$exit_code" -eq 1 ] && [ -d "$tmpdir" ] && [ -z "$(find "$tmpdir" -mindepth 1 -print -quit)" ]; then
    pass "Parquet cleanup removes partial output after Lean file errors"
else
    fail "Parquet cleanup removes partial output after Lean file errors" "$parquet_output"
fi
rm -rf "$tmpdir" "$bad_syntax"

echo ""

# --- Imports Worker Failure Propagation Tests ---
echo "Imports Worker Failure Propagation:"

set +e
build_output=$(lake build LeanScoutTestProject.ThrowingExtractor 2>&1)
build_exit=$?
set -e
if [ "$build_exit" -ne 0 ]; then
    fail "Build test plugin extractor" "$build_output"
else
    set +e
    plugin_output=$(lake run scout \
        --plugin LeanScoutTestProject.ThrowingExtractor \
        --command throwing_imports \
        --jsonl \
        --imports LeanScoutTestProject.Basic 2>&1 >/dev/null)
    plugin_exit=$?
    set -e
    if [ "$plugin_exit" -eq 1 ]; then
        pass "Imports worker failures propagate to the top-level run"
    else
        fail "Imports worker failures propagate to the top-level run" "$plugin_output"
    fi
fi

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
