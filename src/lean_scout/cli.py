"""Main CLI entry point for lean-scout."""

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
from pathlib import Path
from types import FrameType

from .orchestrator import Orchestrator
from .utils import deserialize_schema
from .writer import JsonLinesWriter, ShardedParquetWriter, Writer

logger = logging.getLogger(__name__)


def read_file_list(file_list_path: str, base_path: Path | None = None) -> list[str]:
    """
    Read a list of file paths from a file (one per line).

    Args:
        file_list_path: Path to file containing file paths
        base_path: Optional base directory for resolving relative file_list_path

    Returns:
        List of file paths (stripped of whitespace, empty lines ignored)

    Raises:
        FileNotFoundError: If file doesn't exist
        RuntimeError: If file is empty
    """
    path = Path(file_list_path)
    if base_path is not None and not path.is_absolute():
        path = (base_path / path).resolve()
    if not path.exists():
        raise FileNotFoundError(f"File list not found: {file_list_path}")

    with open(path) as f:
        lines = [line.strip() for line in f if line.strip()]

    if not lines:
        raise RuntimeError(f"File list is empty: {file_list_path}")

    return lines


def query_library_paths(library: str, root_path: Path) -> list[str]:
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


def configure_logging(log_level: str) -> None:
    """Configure root logging for the CLI."""
    logging.basicConfig(
        level=getattr(logging, log_level),
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )


def resolve_directories(
    root_path_arg: str,
    data_dir_arg: str | None,
    cmd_root_arg: str | None,
    command: str,
) -> tuple[Path, Path, Path]:
    """
    Resolve filesystem paths for Lean execution and output locations.

    Returns:
        (root_path, cmd_root, base_path)
    """
    root_path = Path(root_path_arg).expanduser().resolve()

    # Base directory representing the original command invocation
    cmd_root = Path(cmd_root_arg).expanduser() if cmd_root_arg is not None else Path.cwd()
    cmd_root = cmd_root.resolve()

    if data_dir_arg is None:
        data_dir = cmd_root
    else:
        data_dir_candidate = Path(data_dir_arg).expanduser()
        if data_dir_candidate.is_absolute():
            data_dir = data_dir_candidate.resolve()
        else:
            data_dir = (cmd_root / data_dir_candidate).resolve()

    base_path = (data_dir / command).resolve()
    return root_path, cmd_root, base_path


def main() -> None:
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
        """,
    )

    # Required arguments
    parser.add_argument(
        "--command",
        required=True,
        help="Extractor command to run (e.g., types, tactics). Use 'extractors' to list available commands.",
    )

    # Target specification (mutually exclusive, not required for 'extractors' command)
    target_group = parser.add_mutually_exclusive_group(required=False)
    target_group.add_argument(
        "--imports", nargs="+", help="Modules to import (e.g., Lean, Mathlib)"
    )
    target_group.add_argument(
        "--read",
        nargs="+",
        help="Lean file(s) to read and process. Multiple files will be processed in parallel.",
    )
    target_group.add_argument(
        "--readList",
        help="File containing list of Lean files to read (one per line). Files will be processed in parallel.",
    )
    target_group.add_argument(
        "--library",
        help="Library name to extract from (e.g., LeanScoutTest, Mathlib). Queries module paths using lake query -q <library>:module_paths.",
    )

    # Optional arguments
    parser.add_argument("--dataDir", default=None, help="Base output directory (default: cmdRoot)")
    parser.add_argument(
        "--cmdRoot",
        dest="cmdRoot",
        default=None,
        help="Root directory where the command was invoked. Used to resolve relative inputs and outputs "
        "(default: current working directory).",
    )
    parser.add_argument(
        "--numShards", type=int, default=128, help="Number of output shards (default: 128)"
    )
    parser.add_argument(
        "--batchRows", type=int, default=1024, help="Rows per batch before flushing (default: 1024)"
    )
    parser.add_argument(
        "--rootPath", default=".", help="Package root directory (default: current directory)"
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=None,
        help="Number of parallel workers for file extraction (default: CPU count). "
        "Only applies to --read/--readList/--library with multiple files. "
        "Actual workers used: min(num_files, --parallel)",
    )
    parser.add_argument(
        "--logLevel",
        default="INFO",
        type=str.upper,
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Logging level (default: INFO)",
    )
    parser.add_argument(
        "--jsonl",
        action="store_true",
        help="Output JSON Lines to stdout instead of sharded Parquet files",
    )

    args = parser.parse_args()
    configure_logging(args.logLevel)

    # Validate --parallel flag
    # Use number of CPU cores as maximum (default to 32 if can't determine)
    max_workers = os.cpu_count() or 32

    # Set default parallel workers to CPU count if not specified
    if args.parallel is None:
        args.parallel = max_workers
    if args.parallel < 1:
        parser.error(f"--parallel must be at least 1, got {args.parallel}")
    if args.parallel > max_workers:
        logger.warning(
            "--parallel %s exceeds number of CPU cores (%s). Using %s instead.",
            args.parallel,
            max_workers,
            max_workers,
        )
        args.parallel = max_workers

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
        parser.error(
            "one of the arguments --imports --read --readList --library is required (except for 'extractors' command)"
        )

    # Resolve key directories (command root influences both input and output resolution)
    root_path, cmd_root, resolved_base_path = resolve_directories(
        root_path_arg=args.rootPath,
        data_dir_arg=args.dataDir,
        cmd_root_arg=args.cmdRoot,
        command=args.command,
    )
    base_path: Path | None = resolved_base_path
    output_dir: Path | None

    if args.jsonl:
        base_path = None
        output_dir = None
    else:
        output_dir = resolved_base_path
        # Check if output directory already exists
        if output_dir.exists():
            logger.error("Data directory %s already exists. Aborting.", output_dir)
            sys.exit(1)

        # Create output directory
        output_dir.mkdir(parents=True, exist_ok=False)

    orchestrator: Orchestrator | None = None
    writer: Writer | None = None
    interrupted = False

    def sigint_handler(signum: int, frame: FrameType | None) -> None:
        """Handle SIGINT by cleaning up processes immediately."""
        nonlocal interrupted
        if interrupted:
            # Second CTRL-C: force exit
            sys.exit(130)
        interrupted = True
        logger.warning("Interrupted by user. Cleaning up...")
        if orchestrator is not None:
            orchestrator.cleanup()
        if writer is not None:
            writer.close()
        sys.exit(130)

    # Install signal handler for immediate cleanup on CTRL-C
    original_sigint = signal.signal(signal.SIGINT, sigint_handler)

    try:
        # Determine read files list
        read_files = None
        if args.read:
            read_files = args.read
        elif args.readList:
            logger.info("Reading file list from: %s", args.readList)
            read_files = read_file_list(args.readList, base_path=cmd_root)
            logger.info("Found %s files to process", len(read_files))
        elif args.library:
            logger.info("Querying module paths for library: %s", args.library)
            read_files = query_library_paths(args.library, root_path)
            logger.info("Found %s files to process", len(read_files))

        # Create writer
        if args.jsonl:
            writer = JsonLinesWriter()
        else:
            # Parquet path: fetch schema (for shard key and Arrow schema)
            logger.info("Querying schema for command '%s'...", args.command)
            schema_json = get_schema(args.command, root_path)
            schema = deserialize_schema(schema_json)

            # Extract shard key from schema metadata
            schema_obj = json.loads(schema_json)
            if "key" not in schema_obj:
                raise ValueError(
                    f"Schema for command '{args.command}' missing required 'key' field"
                )
            key = schema_obj["key"]

            assert output_dir is not None
            writer = ShardedParquetWriter(
                schema=schema,
                out_dir=str(output_dir),
                num_shards=args.numShards,
                batch_rows=args.batchRows,
                shard_key=key,
            )

        # Create orchestrator
        orchestrator = Orchestrator(
            command=args.command,
            root_path=root_path,
            cmd_root=cmd_root,
            writer=writer,
            imports=args.imports,
            read_files=read_files,
            num_workers=args.parallel,
        )

        # Run extraction
        logger.info("Running extraction for command '%s'...", args.command)
        stats = orchestrator.run()

        # Report results
        if args.jsonl:
            logger.info("Extraction complete! Rows written: %s", stats["total_rows"])
        else:
            logger.info(
                "Extraction complete! Rows written: %s | Shards created: %s | Output directory: %s",
                stats["total_rows"],
                stats["num_shards"],
                stats["out_dir"],
            )

    except KeyboardInterrupt:
        # Fallback: signal handler should have handled this, but just in case
        interrupted = True
        logger.warning("Interrupted by user. Cleaning up...")

    except Exception as e:
        # Clean up output directory on error (only for parquet)
        if base_path is not None and base_path.exists():
            import shutil

            shutil.rmtree(base_path)
        logger.exception("Extraction failed: %s", e)
        sys.exit(1)

    finally:
        # Restore original signal handler
        signal.signal(signal.SIGINT, original_sigint)
        # Ensure cleanup on any exit (including Ctrl+C)
        if orchestrator is not None:
            orchestrator.cleanup()
        if writer is not None and interrupted:
            # Close writer to flush buffered data on interrupt
            writer.close()

    if interrupted:
        sys.exit(130)  # Standard exit code for SIGINT


if __name__ == "__main__":
    main()
