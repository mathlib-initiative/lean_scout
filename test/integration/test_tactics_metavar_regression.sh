#!/usr/bin/env bash
#
# Regression test for tactics extraction on tactic nodes whose `goalsBefore`
# must be interpreted in `TacticInfo.mctxBefore` instead of the current
# `ContextInfo.mctx`.

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
TARGET_FILE="LeanScoutTest/TacticsMetavarRegression.lean"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== Tactics Metavariable Regression Test ==="
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

echo "Checking Lean Scout tactics extraction..."
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
  fail "Lean Scout should extract tactics from $TARGET_FILE" "$(cat "$SCOUT_STDERR")"
fi

if [ ! -s "$SCOUT_STDOUT" ]; then
  fail "Lean Scout should emit tactic records for $TARGET_FILE" "$(cat "$SCOUT_STDERR")"
fi

python3 - "$SCOUT_STDOUT" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
if not records:
    raise SystemExit("no tactic records parsed")

found_have = any(r.get("ppTac") == "have : n < x ∨ n < y" for r in records)
found_grind_seq = any(
    r.get("kind") == "Lean.Parser.Tactic.Grind.grindSeq"
    and "have : n < x ∨ n < y" in r.get("ppTac", "")
    for r in records
)

if not found_have:
    raise SystemExit("missing expected grind have record")
if not found_grind_seq:
    raise SystemExit("missing expected grindSeq record")
PY
pass "Lean Scout extracts the grind regression fixture and preserves grindSeq goals"

echo ""
echo -e "${GREEN}Tactics metavariable regression test passed!${NC}"
