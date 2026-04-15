#!/usr/bin/env bash
#
# Regression test for input-mode frontend defaults using a local minimal repro.
#
# Historically, Lean Scout's manual frontend in `--read` mode diverged from
# `lake env lean` and rejected `LeanScoutTest/InputFrontendRegression.lean`
# before extractor logic ran.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}✓${NC} $1"
}

fail() {
  echo -e "${RED}✗${NC} $1"
  if [ -n "${2:-}" ]; then
    echo -e "${YELLOW}  Output:${NC}"
    echo "$2" | head -40 | sed 's/^/    /'
  fi
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKDIR="$(mktemp -d)"
PLAIN_STDOUT="$WORKDIR/plain.out"
PLAIN_STDERR="$WORKDIR/plain.err"
SCOUT_STDOUT="$WORKDIR/scout.out"
SCOUT_STDERR="$WORKDIR/scout.err"
TARGET_FILE="LeanScoutTest/InputFrontendRegression.lean"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== Input Frontend Regression Test ==="
echo -e "${YELLOW}Repository root:${NC} $REPO_ROOT"
echo -e "${YELLOW}Target file:${NC} $TARGET_FILE"
echo ""

echo "Checking plain Lean control..."
set +e
(
  cd "$REPO_ROOT"
  lake env lean "$TARGET_FILE" >"$PLAIN_STDOUT" 2>"$PLAIN_STDERR"
)
plain_exit=$?
set -e
if [ "$plain_exit" -ne 0 ]; then
  fail "Plain Lean should accept $TARGET_FILE" "$(cat "$PLAIN_STDERR")"
fi
pass "Plain Lean accepts $TARGET_FILE"

echo "Checking Lean Scout input frontend..."
set +e
(
  cd "$REPO_ROOT"
  lake run scout \
    --command tactics \
    --jsonl \
    --parallel 1 \
    --read "$TARGET_FILE" >"$SCOUT_STDOUT" 2>"$SCOUT_STDERR"
)
scout_exit=$?
set -e
if [ "$scout_exit" -ne 0 ]; then
  fail "Lean Scout should process $TARGET_FILE in --read mode" "$(cat "$SCOUT_STDERR")"
fi

if [ ! -s "$SCOUT_STDOUT" ]; then
  fail "Lean Scout should emit tactic records for $TARGET_FILE" "$(cat "$SCOUT_STDERR")"
fi

if ! head -n 1 "$SCOUT_STDOUT" | python3 -c 'import json, sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
  fail "Lean Scout should emit valid JSONL" "$(head -n 5 "$SCOUT_STDOUT")"
fi
pass "Lean Scout processes $TARGET_FILE and emits valid JSONL"

echo ""
echo -e "${GREEN}Input frontend regression test passed!${NC}"
