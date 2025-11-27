#!/usr/bin/env python
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CALLER_ROOT = Path.cwd().resolve()
MANIFEST_PATH = ROOT / "lake-manifest.json"
SUBPROJECT_DIR = Path(tempfile.mkdtemp(prefix="lean_scout_subproject_"))
LEAN_TOOLCHAIN_FILE = ROOT / "lean-toolchain"

try:
    LEAN_TOOLCHAIN = LEAN_TOOLCHAIN_FILE.read_text().strip()
except FileNotFoundError:
    print(f"lean-toolchain not found at {LEAN_TOOLCHAIN_FILE}", file=sys.stderr)
    sys.exit(1)

LEAN_VERSION = LEAN_TOOLCHAIN.split(":")[-1] if LEAN_TOOLCHAIN else ""
if not LEAN_VERSION:
    print(f"lean-toolchain is empty at {LEAN_TOOLCHAIN_FILE}", file=sys.stderr)
    sys.exit(1)

with MANIFEST_PATH.open("r") as f:
    MANIFEST = json.load(f)

PKG_NAME = MANIFEST["name"]

LAKEFILE = f"""
name = "data"
reservoir = false
version = "0.1.0"
packagesDir = "{(ROOT / ".lake" / "packages").as_posix()}"

[[require]]
name = "{PKG_NAME}"
path = "{ROOT.as_posix()}"

[[require]]
name = "lean_scout"
git = "git@github.com:mathlib-initiative/lean_scout.git"
rev = "main"
"""


def ensure_subproject():
    SUBPROJECT_DIR.mkdir(parents=True, exist_ok=True)
    lakefile_path = SUBPROJECT_DIR / "lakefile.toml"
    if not lakefile_path.exists():
        lakefile_path.write_text(LAKEFILE)


ENV = os.environ.copy()
ENV["MATHLIB_NO_CACHE_ON_UPDATE"] = "1"


def run_in_subproject(cmd):
    result = subprocess.run(cmd, cwd=SUBPROJECT_DIR, env=ENV)
    if result.returncode != 0:
        sys.exit(result.returncode)


def main():
    ensure_subproject()

    run_in_subproject(["lake", "build", "-q", "lean_scout"])

    # Pass through all user-provided CLI arguments so extract.py always matches lean-scout's interface.
    lake_cmd = ["lake", "run", "scout", "--cmdRoot", str(CALLER_ROOT), *sys.argv[1:]]
    run_in_subproject(lake_cmd)


if __name__ == "__main__":
    main()
