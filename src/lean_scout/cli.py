"""Main CLI entry point for lean-scout."""
import sys
import argparse
import subprocess
import json
import os
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


def query_library_paths(library: str, root_path: Path) -> List[str]:
    """
    Query module paths for a library using lake query.

    Args:
        library: Library name (e.g., "LeanScoutTest", "Mathlib")
        root_path: Path to package root

    Returns:
        List of file paths from the library

    Raises:
        RuntimeError: If lake query fails
    """
    result = subprocess.run(
        ["lake", "query", "-q", f"{library}:module_paths"],
        cwd=root_path,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Failed to query module paths for library '{library}'\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )

    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]

    return lines


def get_schema(command: str, root_path: Path) -> str:
    """
    Query Lean for the schema of a given extractor command.

    Args:
        command: Extractor command (e.g., "types", "tactics")
        root_path: Path to package root

    Returns:
        Schema JSON string

    Raises:
        RuntimeError: If schema query fails
    """
    result = subprocess.run(
        ["lake", "exe", "-q", "lean_scout", "--command", command, "--schema"],
        cwd=root_path,
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
  # Extract types from Lean as an imported module
  lean-scout --command types --imports Lean

  # Extract types from Mathlib as an imported module (if available as dependency)
  lean-scout --command types --imports Mathlib

  # Extract tactics from a specific file
  lean-scout --command tactics --read LeanScoutTest/TacticsTest.lean

  # Extract from all modules in a library (uses CPU count workers by default)
  lean-scout --command tactics --library LeanScoutTest

  # Limit parallel workers (default is CPU count)
  lean-scout --command tactics --library LeanScoutTest --parallel 4

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
        "--readList",
        help="File containing list of Lean files to read (one per line). Files will be processed in parallel."
    )
    target_group.add_argument(
        "--library",
        help="Library name to extract from (e.g., LeanScoutTest, Mathlib). Queries module paths using lake query -q <library>:module_paths."
    )

    # Optional arguments
    parser.add_argument(
        "--dataDir",
        default=None,
        help="Base output directory (default: rootPath)"
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
        "--rootPath",
        default=".",
        help="Package root directory (default: current directory)"
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=None,
        help="Number of parallel workers for file extraction (default: CPU count). "
             "Only applies to --read/--readList/--library with multiple files. "
             "Actual workers used: min(num_files, --parallel)"
    )

    args = parser.parse_args()

    # Validate --parallel flag
    # Use number of CPU cores as maximum (default to 32 if can't determine)
    MAX_WORKERS = os.cpu_count() or 32

    # Set default parallel workers to CPU count if not specified
    if args.parallel is None:
        args.parallel = MAX_WORKERS
    if args.parallel < 1:
        parser.error(f"--parallel must be at least 1, got {args.parallel}")
    if args.parallel > MAX_WORKERS:
        sys.stderr.write(
            f"Warning: --parallel {args.parallel} exceeds number of CPU cores ({MAX_WORKERS}). "
            f"Using {MAX_WORKERS} instead.\n"
        )
        args.parallel = MAX_WORKERS

    if args.numShards < 1:
        parser.error(f"--numShards must be at least 1, got {args.numShards}")
    if args.numShards > 999:
        parser.error(f"--numShards cannot exceed 999, got {args.numShards}")

    # Handle special "extractors" command early (before validation)
    if args.command == "extractors":
        root_path = Path(args.rootPath).resolve()
        result = subprocess.run(
            ["lake", "exe", "-q", "lean_scout", "--command", "extractors"],
            cwd=root_path,
        )
        sys.exit(result.returncode)

    # Validate that target is specified for all other commands
    if not args.imports and not args.read and not args.readList and not args.library:
        parser.error("one of the arguments --imports --read --readList --library is required (except for 'extractors' command)")

    # Convert paths
    root_path = Path(args.rootPath).resolve()
    data_dir = (root_path / args.dataDir).resolve() if args.dataDir is not None else root_path

    # Determine output path
    base_path = data_dir / args.command
    base_path = base_path.resolve()

    # Check if output directory already exists
    if base_path.exists():
        sys.stderr.write(f"Error: Data directory {base_path} already exists. Aborting.\n")
        sys.exit(1)

    # Create output directory
    base_path.mkdir(parents=True, exist_ok=False)

    try:
        # Determine read files list
        read_files = None
        if args.read:
            read_files = args.read
        elif args.readList:
            sys.stderr.write(f"Reading file list from: {args.readList}\n")
            read_files = read_file_list(args.readList)
            sys.stderr.write(f"Found {len(read_files)} files to process\n")
        elif args.library:
            sys.stderr.write(f"Querying module paths for library: {args.library}\n")
            read_files = query_library_paths(args.library, root_path)
            sys.stderr.write(f"Found {len(read_files)} files to process\n")

        # Query schema from Lean
        sys.stderr.write(f"Querying schema for command '{args.command}'...\n")
        schema_json = get_schema(args.command, root_path)
        schema = deserialize_schema(schema_json)

        # Extract shard key from schema metadata
        schema_obj = json.loads(schema_json)
        if "key" not in schema_obj:
            raise ValueError(f"Schema for command '{args.command}' missing required 'key' field")
        key = schema_obj["key"]

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
            root_path=root_path,
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
