#!/bin/env bash

set -e  # Exit on error

SUBPROJECT_DIR=data_extractor_subproject

mkdir $SUBPROJECT_DIR
cd $SUBPROJECT_DIR

# Create lakefile.toml
cat > lakefile.toml << 'EOF'
name = "data"
reservoir = false
version = "0.1.0"
packagesDir = "../.lake/packages"

[[require]]
name = "lean_scout"
git = "git@github.com:mathlib-initiative/lean_scout.git"
rev = "main"
EOF

MATHLIB_NO_CACHE_ON_UPDATE=1

lake build lean_scout
