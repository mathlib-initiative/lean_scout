"""Orchestrates Lean subprocess execution and coordinates data writing."""
import subprocess
import sys
import json
from typing import Optional, List
from pathlib import Path

from .utils import stream_json_lines
from .writer import ShardedParquetWriter


class Orchestrator:
    """Manages Lean subprocess execution and coordinates writing to shared Parquet writers."""

    def __init__(
        self,
        command: str,
        scout_path: Path,
        writer: ShardedParquetWriter,
        imports: Optional[List[str]] = None,
        read_file: Optional[str] = None,
        num_workers: int = 1,
    ):
        """
        Initialize orchestrator.

        Args:
            command: Extractor command (e.g., "types", "tactics")
            scout_path: Path to Scout package root directory
            writer: Shared ShardedParquetWriter instance
            imports: List of modules to import (for .imports target)
            read_file: Lean file to read (for .input target)
            num_workers: Number of parallel Lean workers (default: 1, sequential)
        """
        self.command = command
        self.scout_path = Path(scout_path)
        self.writer = writer
        self.imports = imports
        self.read_file = read_file
        self.num_workers = num_workers

        # Validate arguments
        if imports and read_file:
            raise ValueError("Cannot specify both --imports and --read")
        if not imports and not read_file:
            raise ValueError("Must specify either --imports or --read")

    def run(self) -> dict:
        """
        Run extraction and return statistics.

        Returns:
            Dictionary with statistics: total_rows, num_shards, etc.
        """
        # For now, implement sequential execution
        # Phase 6 will add parallel execution
        if self.num_workers > 1:
            sys.stderr.write(
                f"Warning: Parallel execution not yet implemented. "
                f"Running sequentially (num_workers={self.num_workers} ignored).\n"
            )

        process = self._spawn_lean_subprocess()
        self._process_subprocess_output(process)

        # Wait for subprocess to complete
        returncode = process.wait()
        if returncode != 0:
            stderr_output = process.stderr.read() if process.stderr else ""
            raise RuntimeError(
                f"Lean subprocess failed with exit code {returncode}\n"
                f"stderr: {stderr_output}"
            )

        # Close writer and get statistics
        return self.writer.close()

    def _spawn_lean_subprocess(self) -> subprocess.Popen:
        """
        Spawn a single Lean extractor subprocess.

        Returns:
            subprocess.Popen instance
        """
        # Build command line arguments
        args = [
            "lake", "exe", "lean_scout",
            "--scoutPath", str(self.scout_path),
            "--command", self.command,
        ]

        # Add target specification
        if self.imports:
            args.append("--imports")
            args.extend(self.imports)
        elif self.read_file:
            args.extend(["--read", self.read_file])

        # Spawn subprocess
        # stdout: piped (we read JSON from here)
        # stderr: inherited (error messages go to user's terminal)
        # stdin: closed (Lean doesn't need input)
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,  # Line buffered
            cwd=self.scout_path,
        )

        return process

    def _process_subprocess_output(self, process: subprocess.Popen) -> None:
        """
        Read JSON lines from subprocess stdout and feed to writer.

        Args:
            process: subprocess.Popen instance with stdout to read
        """
        if not process.stdout:
            raise RuntimeError("Subprocess stdout is not available")

        # Stream JSON lines and add to writer
        for record in stream_json_lines(process.stdout):
            self.writer.add_record(record)

        # Ensure all data is flushed
        self.writer.flush_all()
