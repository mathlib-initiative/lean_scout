#!/bin/env python
import json
import os
import subprocess

with open("lake-manifest.json", "r") as f:
    MANIFEST = json.load(f)

PKG_NAME = MANIFEST["name"]

SUBPROJECT_DIR="data_extractor_subproject"

os.mkdir(SUBPROJECT_DIR)

LAKEFILE = f"""
name = "data"
reservoir = false
version = "0.1.0"
packagesDir = "../.lake/packages"

[[require]]
name = "{PKG_NAME}"
path = "../"

[[require]]
name = "lean_scout"
git = "git@github.com:mathlib-initiative/lean_scout.git"
rev = "main"
""" 

with open(os.path.join(SUBPROJECT_DIR, "lakefile.toml"), "w") as f:
    f.write(LAKEFILE)

# Run lake build in the subdirectory
env = os.environ.copy()
env["MATHLIB_NO_CACHE_ON_UPDATE"] = "1"

result = subprocess.run(
    ["lake", "build", "lean_scout"],
    cwd=SUBPROJECT_DIR,
    env=env
)

if result.returncode != 0:
    exit(1)
