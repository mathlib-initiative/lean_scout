#!/usr/bin/env python
"""Wrapper script for using Lean Scout as a dependency in other projects."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CALLER_ROOT = Path.cwd().resolve()
MANIFEST_PATH = ROOT / "lake-manifest.json"
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


def get_lakefile_content() -> str:
    """Generate lakefile.toml content for the subproject."""
    return f"""
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


def get_environment() -> dict[str, str]:
    """Get environment with MATHLIB_NO_CACHE_ON_UPDATE disabled."""
    env = os.environ.copy()
    env["MATHLIB_NO_CACHE_ON_UPDATE"] = "1"
    return env


def ensure_subproject(subproject_dir: Path) -> None:
    """Create subproject directory and lakefile if needed."""
    subproject_dir.mkdir(parents=True, exist_ok=True)
    lakefile_path = subproject_dir / "lakefile.toml"
    if not lakefile_path.exists():
        lakefile_path.write_text(get_lakefile_content())
    # Copy lean-toolchain to ensure the subproject uses the same Lean version
    toolchain_dest = subproject_dir / "lean-toolchain"
    if not toolchain_dest.exists():
        toolchain_dest.write_text(LEAN_TOOLCHAIN + "\n")


def run_in_subproject(cmd: list[str], subproject_dir: Path) -> None:
    """Run command in subproject directory, exiting on failure."""
    result = subprocess.run(cmd, cwd=subproject_dir, env=get_environment())
    if result.returncode != 0:
        sys.exit(result.returncode)


def main() -> None:
    """Main entry point using temporary directory context manager."""
    with tempfile.TemporaryDirectory(prefix="lean_scout_subproject_") as tmpdir:
        subproject_dir = Path(tmpdir)
        ensure_subproject(subproject_dir)

        run_in_subproject(["lake", "build", "-q", "lean_scout"], subproject_dir)

        # Pass through all user-provided CLI arguments so extract.py always matches lean-scout's interface.
        lake_cmd = ["lake", "run", "scout", "--cmdRoot", str(CALLER_ROOT), *sys.argv[1:]]
        run_in_subproject(lake_cmd, subproject_dir)


if __name__ == "__main__":
    main()
