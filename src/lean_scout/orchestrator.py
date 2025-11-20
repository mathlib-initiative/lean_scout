"""Orchestrates Lean subprocess execution and coordinates data writing."""
import logging
import subprocess
from typing import Optional, List, Protocol, IO, Any
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

from .utils import stream_json_lines
from .writer import ShardedParquetWriter


class ProcessProtocol(Protocol):
    """Protocol for subprocess-like objects that can be used for extraction."""
    stdout: Optional[IO[Any]]


logger = logging.getLogger(__name__)


class Orchestrator:
    """Manages Lean subprocess execution and coordinates writing to shared Parquet writers."""

    def __init__(
        self,
        command: str,
        root_path: Path,
        writer: ShardedParquetWriter,
        imports: Optional[List[str]] = None,
        read_files: Optional[List[str]] = None,
        num_workers: int = 1,
    ):
        """
        Initialize orchestrator.

        Args:
            command: Extractor command (e.g., "types", "tactics")
            root_path: Path to package root directory
            writer: Shared ShardedParquetWriter instance
            imports: List of modules to import (for .imports target)
            read_files: List of Lean files to read (for .input target, parallel processing)
            num_workers: Number of parallel Lean workers (default: 1, sequential)
        """
        self.command = command
        self.root_path = Path(root_path)
        self.writer = writer
        self.imports = imports
        self.read_files = read_files
        self.num_workers = num_workers

        # Validate arguments
        if imports and read_files:
            raise ValueError("Cannot specify both --imports and --read")
        if not imports and not read_files:
            raise ValueError("Must specify either --imports or --read")

    def run(self) -> dict:
        """
        Run extraction and return statistics.

        For .imports target: Single subprocess
        For .read target with multiple files: Parallel subprocesses (one per file)

        Returns:
            Dictionary with statistics: total_rows, num_shards, etc.
        """

        if self.imports:
            self._run_imports()

        elif self.read_files:
            num_files = len(self.read_files)

            if num_files == 1:
                self._run_single_file()

            else:
                self._run_multiple_files()

        return self.writer.close()

    def _run_imports(self) -> None:
        logger.info("Running single subprocess for imports target...")
        process = self._spawn_lean_subprocess()
        self._process_subprocess_output(process)

        # Wait for subprocess to complete
        returncode = process.wait()
        if returncode != 0:
            raise RuntimeError(
                f"Lean subprocess failed with exit code {returncode}"
            )

    def _run_single_file(self) -> None:

        assert self.read_files is not None and len(self.read_files) == 1, "Expected exactly one read file"

        logger.info("Processing single file: %s", self.read_files[0])
        process = self._spawn_lean_subprocess(self.read_files[0])
        self._process_subprocess_output(process)

        returncode = process.wait()
        if returncode != 0:
            raise RuntimeError(
                f"Lean subprocess failed with exit code {returncode}\n"
                f"File: {self.read_files[0]}"
            )

    def _run_multiple_files(self) -> None:

        assert self.read_files is not None and len(self.read_files) > 1, "Expected multiple read files"

        num_files = len(self.read_files)
        max_workers = min(self.num_workers, num_files)

        logger.info("Processing %s files in parallel with %s workers...", num_files, max_workers)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_to_file = {
                executor.submit(self._process_file, file_path): file_path
                for file_path in self.read_files
            }

            completed = 0
            failed = 0
            errors = []
            for future in as_completed(future_to_file):
                file_path = future_to_file[future]
                try:
                    future.result()
                    completed += 1
                    logger.info("[%s/%s] Completed: %s", completed + failed, num_files, file_path)
                except Exception as exc:
                    failed += 1
                    error_msg = f"{file_path}: {exc}"
                    errors.append(error_msg)
                    logger.error("[%s/%s] Failed: %s", completed + failed, num_files, error_msg)

            if errors:
                raise RuntimeError(
                    f"Failed to process {failed}/{num_files} files:\n" +
                    "\n".join(f"  - {err}" for err in errors)
                )

    def _spawn_lean_subprocess(self, file_path: Optional[str] = None) -> subprocess.Popen:
        """
        Spawn a single Lean extractor subprocess.

        Args:
            file_path: Optional file path for .read target (overrides self.read_files)

        Returns:
            subprocess.Popen instance
        """

        assert self.imports or file_path, "Either imports or file_path must be specified"

        args = [
            "lake", "exe", "-q", "lean_scout",
            "--command", self.command,
        ]

        if self.imports:
            args.append("--imports")
            args.extend(self.imports)
        elif file_path:
            args.extend(["--read", file_path])

        # stdout: piped for JSON output
        # stderr: inherit parent's stderr (no buffering issues)
        # stdin: closed (not needed)
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=None,  # Inherit parent's stderr
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            cwd=self.root_path,
        )

        return process

    def _process_file(self, file_path: str) -> None:
        """
        Process a single file: spawn subprocess, read output, write to shared writer.

        This method is called by ThreadPoolExecutor for parallel file processing.

        Args:
            file_path: Path to Lean file to process

        Raises:
            RuntimeError: If subprocess fails
        """
        process = self._spawn_lean_subprocess(file_path)
        self._process_subprocess_output(process)

        returncode = process.wait()
        if returncode != 0:
            raise RuntimeError(
                f"Lean subprocess failed with exit code {returncode}\n"
                f"File: {file_path}"
            )

    def _process_subprocess_output(self, process: ProcessProtocol) -> None:
        """
        Read JSON lines from subprocess stdout and feed to writer.

        Args:
            process: Process-like object with stdout to read
        """
        if not process.stdout:
            raise RuntimeError("Subprocess stdout is not available")

        for record in stream_json_lines(process.stdout):
            self.writer.add_record(record)
