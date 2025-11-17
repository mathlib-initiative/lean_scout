"""Main CLI entry point for lean-scout."""
import sys
import argparse
import subprocess
import json
from pathlib import Path
from typing import List

from .utils import deserialize_schema
from .writer import ShardedParquetWriter
from .orchestrator import Orchestrator


def read_file_list(file_list_path: str) -> List[str]:
    """
    Read a list of file paths from a file (one per line).

    Args:
        file_list_path: Path to file containing file paths

    Returns:
        List of file paths (stripped of whitespace, empty lines ignored)

    Raises:
        FileNotFoundError: If file doesn't exist
        RuntimeError: If file is empty
    """
    path = Path(file_list_path)
    if not path.exists():
        raise FileNotFoundError(f"File list not found: {file_list_path}")

    with open(path, 'r') as f:
        lines = [line.strip() for line in f if line.strip()]

    if not lines:
        raise RuntimeError(f"File list is empty: {file_list_path}")

    return lines


def get_schema(command: str, scout_path: Path) -> str:
    """
    Query Lean for the schema of a given extractor command.

    Args:
        command: Extractor command (e.g., "types", "tactics")
        scout_path: Path to Scout package root

    Returns:
        Schema JSON string

    Raises:
        RuntimeError: If schema query fails
    """
    result = subprocess.run(
        ["lake", "exe", "lean_scout", "--scoutPath", str(scout_path), "--command", command, "--schema"],
        cwd=scout_path,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Failed to query schema for command '{command}'\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )

    # Schema should be a single JSON object on stdout
    schema_json = result.stdout.strip()
    if not schema_json:
        raise RuntimeError(f"No schema output for command '{command}'")

    return schema_json


def main():
    """Main CLI entry point for lean-scout."""
    parser = argparse.ArgumentParser(
        description="Extract structured data from Lean4 projects",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Extract types from Lean standard library
  lean-scout --command types --imports Lean

  # Extract types from Mathlib (if available as dependency)
  lean-scout --command types --imports Mathlib

  # Extract tactics from a specific file
  lean-scout --command tactics --read LeanScoutTest/TacticsTest.lean

  # Specify custom data directory and sharding
  lean-scout --command types --dataDir ~/storage --numShards 32 --imports Lean
        """
    )

    # Required arguments
    parser.add_argument(
        "--command",
        required=True,
        help="Extractor command to run (e.g., types, tactics). Use 'extractors' to list available commands."
    )

    # Target specification (mutually exclusive, not required for 'extractors' command)
    target_group = parser.add_mutually_exclusive_group(required=False)
    target_group.add_argument(
        "--imports",
        nargs='+',
        help="Modules to import (e.g., Lean, Mathlib)"
    )
    target_group.add_argument(
        "--read",
        nargs='+',
        help="Lean file(s) to read and process. Multiple files will be processed in parallel."
    )
    target_group.add_argument(
        "--read-list",
        help="File containing list of Lean files to read (one per line). Files will be processed in parallel."
    )

    # Optional arguments
    parser.add_argument(
        "--dataDir",
        default=".",
        help="Base output directory (default: current directory)"
    )
    parser.add_argument(
        "--numShards",
        type=int,
        default=128,
        help="Number of output shards (default: 128)"
    )
    parser.add_argument(
        "--batchRows",
        type=int,
        default=1024,
        help="Rows per batch before flushing (default: 1024)"
    )
    parser.add_argument(
        "--scoutPath",
        default=".",
        help="Scout package root directory (default: current directory)"
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=1,
        help="Number of parallel workers for file extraction (default: 1). "
             "Only applies to --read/--read-list with multiple files. "
             "Actual workers used: min(num_files, --parallel)"
    )

    args = parser.parse_args()

    # Handle special "extractors" command early (before validation)
    if args.command == "extractors":
        scout_path = Path(args.scoutPath).resolve()
        result = subprocess.run(
            ["lake", "exe", "lean_scout", "--scoutPath", str(scout_path), "--command", "extractors"],
            cwd=scout_path,
        )
        sys.exit(result.returncode)

    # Validate that target is specified for all other commands
    if not args.imports and not args.read and not args.read_list:
        parser.error("one of the arguments --imports --read --read-list is required (except for 'extractors' command)")

    # Convert paths
    scout_path = Path(args.scoutPath).resolve()
    data_dir = Path(args.dataDir).resolve()

    # Determine output path
    base_path = data_dir / args.command
    base_path = base_path.resolve()

    # Check if output directory already exists
    if base_path.exists():
        sys.stderr.write(f"Error: Data directory {base_path} already exists. Aborting.\n")
        sys.exit(1)

    # Create output directory
    base_path.mkdir(parents=True, exist_ok=True)

    try:
        # Determine read files list
        read_files = None
        if args.read:
            read_files = args.read
        elif args.read_list:
            sys.stderr.write(f"Reading file list from: {args.read_list}\n")
            read_files = read_file_list(args.read_list)
            sys.stderr.write(f"Found {len(read_files)} files to process\n")

        # Query schema from Lean
        sys.stderr.write(f"Querying schema for command '{args.command}'...\n")
        schema_json = get_schema(args.command, scout_path)
        schema = deserialize_schema(schema_json)

        # Get the key field from the schema metadata
        # We need to query this from Lean as well
        # For now, we'll pass it in the schema JSON
        schema_obj = json.loads(schema_json)
        key = schema_obj.get("key", "name")  # Default to "name" if not specified

        # Create writer
        writer = ShardedParquetWriter(
            schema=schema,
            out_dir=str(base_path),
            num_shards=args.numShards,
            batch_rows=args.batchRows,
            shard_key=key,
        )

        # Create orchestrator
        orchestrator = Orchestrator(
            command=args.command,
            scout_path=scout_path,
            writer=writer,
            imports=args.imports,
            read_files=read_files,
            num_workers=args.parallel,
        )

        # Run extraction
        sys.stderr.write(f"Running extraction for command '{args.command}'...\n")
        stats = orchestrator.run()

        # Report results
        sys.stderr.write(
            f"\nExtraction complete!\n"
            f"  Rows written: {stats['total_rows']}\n"
            f"  Shards created: {stats['num_shards']}\n"
            f"  Output directory: {stats['out_dir']}\n"
        )

    except Exception as e:
        # Clean up output directory on error
        if base_path.exists():
            import shutil
            shutil.rmtree(base_path)
        sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
