#!/bin/env python
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "lake-manifest.json"
SUBPROJECT_DIR = ROOT / "data_extractor_subproject"

with MANIFEST_PATH.open("r") as f:
    MANIFEST = json.load(f)

PKG_NAME = MANIFEST["name"]

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Set up a subproject and run lean-scout within it.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python setup_subproject.py --command types --imports Lean
  python setup_subproject.py --command tactics --read LeanScoutTest/TacticsTest.lean
  python setup_subproject.py --command tactics --library LeanScoutTest --dataDir /tmp/out
        """,
    )

    parser.add_argument(
        "--command",
        required=True,
        help="Extractor command to run (e.g., types, tactics). Use 'extractors' to list available commands.",
    )

    target_group = parser.add_mutually_exclusive_group(required=False)
    target_group.add_argument(
        "--imports",
        nargs="+",
        help="Modules to import (e.g., Lean, Mathlib).",
    )
    target_group.add_argument(
        "--read",
        nargs="+",
        help="Lean file(s) to read and process. Multiple files will be processed in parallel.",
    )
    target_group.add_argument(
        "--library",
        help="Library name to extract from (e.g., LeanScoutTest, Mathlib). Queries module paths using lake query -q <library>:module_paths.",
    )

    parser.add_argument(
        "--dataDir",
        default=None,
        help="Base output directory (default: subproject root).",
    )

    args = parser.parse_args()

    if (
        args.command != "extractors"
        and not args.imports
        and not args.read
        and not args.library
    ):
        parser.error(
            "one of the arguments --imports --read --library is required (except for 'extractors' command)"
        )

    return args


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


def build_lake_command(args: argparse.Namespace) -> list[str]:
    cmd = ["lake", "run", "scout", "--command", args.command]

    if args.dataDir is not None:
        cmd.extend(["--dataDir", args.dataDir])

    if args.imports:
        cmd.extend(["--imports", *args.imports])
    elif args.read:
        cmd.extend(["--read", *args.read])
    elif args.library:
        cmd.extend(["--library", args.library])

    return cmd


def main():
    args = parse_args()
    ensure_subproject()

    run_in_subproject(["lake", "build", "lean_scout"])
    lake_cmd = build_lake_command(args)
    run_in_subproject(lake_cmd)


if __name__ == "__main__":
    main()
