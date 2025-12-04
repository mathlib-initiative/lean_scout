#!/usr/bin/env bash
#
# Wrapper script for using Lean Scout as a dependency in other projects.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mathlib-initiative/lean_scout/main/extract.sh | bash -s -- --command tactics --parquet --library MyLibrary
#
# Or download and run locally:
#   ./extract.sh --command tactics --parquet --library MyLibrary
#
# This script creates a temporary subproject that depends on both your project
# and lean_scout, builds lean_scout, then runs the scout command.
#

set -e

ROOT="$(pwd)"
CALLER_ROOT="$ROOT"
MANIFEST_PATH="$ROOT/lake-manifest.json"
LEAN_TOOLCHAIN_FILE="$ROOT/lean-toolchain"

echo "==> Reading project configuration..."

# Read lean-toolchain
if [ ! -f "$LEAN_TOOLCHAIN_FILE" ]; then
    echo "lean-toolchain not found at $LEAN_TOOLCHAIN_FILE" >&2
    exit 1
fi
LEAN_TOOLCHAIN=$(cat "$LEAN_TOOLCHAIN_FILE" | tr -d '[:space:]')

# Extract version from toolchain (after the colon)
LEAN_VERSION="${LEAN_TOOLCHAIN##*:}"
if [ -z "$LEAN_VERSION" ]; then
    echo "lean-toolchain is empty at $LEAN_TOOLCHAIN_FILE" >&2
    exit 1
fi

# Read package name from lake-manifest.json
if [ ! -f "$MANIFEST_PATH" ]; then
    echo "lake-manifest.json not found at $MANIFEST_PATH" >&2
    exit 1
fi

# Parse JSON - prefer jq if available, fall back to python3
if command -v jq &> /dev/null; then
    PKG_NAME=$(jq -r '.name' "$MANIFEST_PATH")
else
    PKG_NAME=$(python3 -c "import json; print(json.load(open('$MANIFEST_PATH'))['name'])")
fi

if [ -z "$PKG_NAME" ]; then
    echo "Failed to read package name from $MANIFEST_PATH" >&2
    exit 1
fi

echo "    Package: $PKG_NAME"
echo "    Lean version: $LEAN_VERSION"

echo "==> Creating temporary subproject..."

# Create temporary directory
SUBPROJECT_DIR=$(mktemp -d -t lean_scout_subproject_XXXXXX)
trap "rm -rf $SUBPROJECT_DIR" EXIT

# Generate lakefile.toml
PACKAGES_DIR="$ROOT/.lake/packages"
cat > "$SUBPROJECT_DIR/lakefile.toml" << EOF
name = "data"
reservoir = false
version = "0.1.0"
packagesDir = "$PACKAGES_DIR"

[[require]]
name = "$PKG_NAME"
path = "$ROOT"

[[require]]
name = "lean_scout"
git = "https://github.com/mathlib-initiative/lean_scout.git"
rev = "$LEAN_VERSION"
EOF

# Copy lean-toolchain
echo "$LEAN_TOOLCHAIN" > "$SUBPROJECT_DIR/lean-toolchain"

# Set environment to disable Mathlib cache updates
export MATHLIB_NO_CACHE_ON_UPDATE=1

echo "==> Building project..."
lake build -q

echo "==> Building lean_scout..."
cd "$SUBPROJECT_DIR"
lake build -q lean_scout

echo "==> Running extraction..."
lake run scout --cmdRoot "$CALLER_ROOT" "$@"
