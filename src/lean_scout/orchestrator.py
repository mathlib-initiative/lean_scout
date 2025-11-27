"""Orchestrates Lean subprocess execution and coordinates data writing."""

import contextlib
import logging
import os
import signal
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import IO, Any, Protocol

from .utils import stream_json_lines
from .writer import Writer


class ProcessProtocol(Protocol):
    """Protocol for subprocess-like objects that can be used for extraction."""

    stdout: IO[Any] | None


logger = logging.getLogger(__name__)


class Orchestrator:
    """Manages Lean subprocess execution and coordinates writing to shared Parquet writers."""

    def __init__(
        self,
        command: str,
        root_path: Path,
        cmd_root: Path,
        writer: Writer,
        imports: list[str] | None = None,
        read_files: list[str] | None = None,
        num_workers: int = 1,
    ) -> None:
        """
        Initialize orchestrator.

        Args:
            command: Extractor command (e.g., "types", "tactics")
            root_path: Path to package root directory
            cmd_root: Path where the CLI command was invoked (for resolving relative inputs)
            writer: Shared ShardedParquetWriter instance
            imports: List of modules to import (for .imports target)
            read_files: List of Lean files to read (for .input target, parallel processing)
            num_workers: Number of parallel Lean workers (default: 1, sequential)
        """
        self.command = command
        self.root_path = Path(root_path).resolve()
        self.cmd_root = Path(cmd_root).resolve()
        self.writer = writer
        self.imports = imports
        self.read_files = read_files
        self.num_workers = num_workers

        # Process tracking for cleanup
        self._processes: list[subprocess.Popen[str]] = []
        self._process_lock = threading.Lock()
        self._shutdown = False  # Flag to prevent spawning new processes during cleanup

        # Validate arguments
        if imports and read_files:
            raise ValueError("Cannot specify both --imports and --read")
        if not imports and not read_files:
            raise ValueError("Must specify either --imports or --read")

        if self.read_files:
            self.read_files = self._normalize_read_paths(self.read_files)

    def run(self) -> dict[str, Any]:
        """
        Run extraction and return statistics.

        For .imports target: Single subprocess
        For .read target with multiple files: Parallel subprocesses (one per file)

        Returns:
            Dictionary with statistics: total_rows, num_shards, etc.
        """
        # Build lean_scout first so subprocesses don't need to build it
        self._build_lean_scout()

        if self.imports:
            self._run_imports()

        elif self.read_files:
            num_files = len(self.read_files)

            if num_files == 1:
                self._run_single_file()

            else:
                self._run_multiple_files()

        return self.writer.close()

    def _build_lean_scout(self) -> None:
        """Build lean_scout executable before spawning subprocesses."""
        logger.info("Building lean_scout...")
        result = subprocess.run(
            ["lake", "build", "-q", "lean_scout"],
            cwd=self.root_path,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"Failed to build lean_scout (exit code {result.returncode})\n"
                f"stderr: {result.stderr}"
            )
        logger.info("lean_scout build completed successfully")

    def _run_imports(self) -> None:
        logger.info("Running single subprocess for imports target...")
        process = self._spawn_lean_subprocess()
        self._process_subprocess_output(process)

        # Wait for subprocess to complete
        returncode = process.wait()
        if returncode != 0:
            raise RuntimeError(f"Lean subprocess failed with exit code {returncode}")

    def _run_single_file(self) -> None:
        assert self.read_files is not None and len(self.read_files) == 1, (
            "Expected exactly one read file"
        )

        logger.info("Processing single file: %s", self.read_files[0])
        process = self._spawn_lean_subprocess(self.read_files[0])
        self._process_subprocess_output(process)

        returncode = process.wait()
        if returncode != 0:
            raise RuntimeError(
                f"Lean subprocess failed with exit code {returncode}\nFile: {self.read_files[0]}"
            )

    def _run_multiple_files(self) -> None:
        assert self.read_files is not None and len(self.read_files) > 1, (
            "Expected multiple read files"
        )

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
                    f"Failed to process {failed}/{num_files} files:\n"
                    + "\n".join(f"  - {err}" for err in errors)
                )

    def _spawn_lean_subprocess(self, file_path: str | None = None) -> subprocess.Popen[str]:
        """
        Spawn a single Lean extractor subprocess.

        Args:
            file_path: Optional file path for .read target (overrides self.read_files)

        Returns:
            subprocess.Popen instance
        """

        assert self.imports or file_path, "Either imports or file_path must be specified"

        args = [
            "lake",
            "exe",
            "-q",
            "lean_scout",
            "--command",
            self.command,
        ]

        if self.imports:
            args.append("--imports")
            args.extend(self.imports)
        elif file_path:
            args.extend(["--read", file_path])

        # stdout: piped for JSON output
        # stderr: inherit parent's stderr (no buffering issues)
        # stdin: closed (not needed)
        # start_new_session: create new process group so we can kill entire tree
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=None,  # Inherit parent's stderr
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            cwd=self.root_path,
            start_new_session=True,  # Create new process group for cleanup
        )

        # Track process for cleanup
        with self._process_lock:
            self._processes.append(process)

        return process

    def _process_file(self, file_path: str) -> None:
        """
        Process a single file: spawn subprocess, read output, write to shared writer.

        This method is called by ThreadPoolExecutor for parallel file processing.

        Args:
            file_path: Path to Lean file to process

        Raises:
            RuntimeError: If subprocess fails or shutdown is in progress
        """
        # Check if shutdown was requested before spawning new process
        if self._shutdown:
            raise RuntimeError("Shutdown in progress, not spawning new process")

        process = self._spawn_lean_subprocess(file_path)
        try:
            self._process_subprocess_output(process)

            returncode = process.wait()
            if returncode != 0:
                raise RuntimeError(
                    f"Lean subprocess failed with exit code {returncode}\nFile: {file_path}"
                )
        finally:
            # Remove from tracking after completion
            with self._process_lock:
                if process in self._processes:
                    self._processes.remove(process)

    def _normalize_read_paths(self, read_files: list[str]) -> list[str]:
        """
        Resolve relative read paths against the command root, falling back to the package root when needed.
        """
        normalized: list[str] = []
        for file_path in read_files:
            candidate = Path(file_path).expanduser()
            if candidate.is_absolute():
                normalized.append(str(candidate.resolve()))
                continue

            cmd_candidate = (self.cmd_root / candidate).resolve()
            root_candidate = (self.root_path / candidate).resolve()

            if cmd_candidate.exists() or not root_candidate.exists():
                normalized.append(str(cmd_candidate))
            else:
                normalized.append(str(root_candidate))

        return normalized

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

    def cleanup(self) -> None:
        """Terminate all running subprocesses and their children for graceful shutdown."""
        # Set shutdown flag to prevent new processes from being spawned
        self._shutdown = True

        with self._process_lock:
            processes = list(self._processes)

        if not processes:
            return

        logger.info("Terminating %d subprocess(es)...", len(processes))

        # Send SIGTERM to all process groups (kills lake and its children)
        for process in processes:
            if process.poll() is None:  # Still running
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(process.pid, signal.SIGTERM)

        # Wait for graceful termination, then force kill if needed
        for process in processes:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                logger.warning("Process %d did not terminate gracefully, forcing...", process.pid)
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
