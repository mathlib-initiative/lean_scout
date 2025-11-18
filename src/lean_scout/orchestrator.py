"""Orchestrates Lean subprocess execution and coordinates data writing."""
import subprocess
import sys
from typing import Optional, List
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

from .utils import stream_json_lines
from .writer import ShardedParquetWriter


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
        # Imports target: single subprocess
        if self.imports:
            sys.stderr.write("Running single subprocess for imports target...\n")
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

        # Read target: parallel subprocesses (one per file)
        elif self.read_files:
            num_files = len(self.read_files)

            # For single file, run sequentially
            if num_files == 1:
                sys.stderr.write(f"Processing single file: {self.read_files[0]}\n")
                process = self._spawn_lean_subprocess(self.read_files[0])
                self._process_subprocess_output(process)

                returncode = process.wait()
                if returncode != 0:
                    stderr_output = process.stderr.read() if process.stderr else ""
                    raise RuntimeError(
                        f"Lean subprocess failed with exit code {returncode}\n"
                        f"File: {self.read_files[0]}\n"
                        f"stderr: {stderr_output}"
                    )

            # For multiple files, run in parallel
            else:
                # Determine actual number of workers
                max_workers = min(self.num_workers, num_files)
                sys.stderr.write(
                    f"Processing {num_files} files in parallel with {max_workers} workers...\n"
                )

                # Use ThreadPoolExecutor for parallel execution
                with ThreadPoolExecutor(max_workers=max_workers) as executor:
                    # Submit all file processing tasks
                    future_to_file = {
                        executor.submit(self._process_file, file_path): file_path
                        for file_path in self.read_files
                    }

                    # Wait for completion and collect errors
                    completed = 0
                    failed = 0
                    errors = []
                    for future in as_completed(future_to_file):
                        file_path = future_to_file[future]
                        try:
                            future.result()
                            completed += 1
                            sys.stderr.write(f"  [{completed + failed}/{num_files}] Completed: {file_path}\n")
                        except Exception as exc:
                            failed += 1
                            error_msg = f"{file_path}: {exc}"
                            errors.append(error_msg)
                            sys.stderr.write(f"  [{completed + failed}/{num_files}] Failed: {error_msg}\n")

                    # Raise error if any files failed
                    if errors:
                        raise RuntimeError(
                            f"Failed to process {failed}/{num_files} files:\n" +
                            "\n".join(f"  - {err}" for err in errors)
                        )

        # Close writer and get statistics
        return self.writer.close()

    def _spawn_lean_subprocess(self, file_path: Optional[str] = None) -> subprocess.Popen:
        """
        Spawn a single Lean extractor subprocess.

        Args:
            file_path: Optional file path for .read target (overrides self.read_files)

        Returns:
            subprocess.Popen instance
        """
        # Build command line arguments
        args = [
            "lake", "exe", "lean_scout",
            "--command", self.command,
        ]

        # Add target specification
        if self.imports:
            args.append("--imports")
            args.extend(self.imports)
        elif file_path:
            args.extend(["--read", file_path])
        elif self.read_files:
            # Use first file if no specific file_path provided
            args.extend(["--read", self.read_files[0]])

        # Spawn subprocess
        # stdout: piped for JSON output
        # stderr: captured for error reporting
        # stdin: closed (not needed)
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
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
        Thread-safe due to ShardedParquetWriter's locking.

        Args:
            file_path: Path to Lean file to process

        Raises:
            RuntimeError: If subprocess fails
        """
        process = self._spawn_lean_subprocess(file_path)
        self._process_subprocess_output(process)

        # Wait for subprocess to complete
        returncode = process.wait()
        if returncode != 0:
            stderr_output = process.stderr.read() if process.stderr else ""
            raise RuntimeError(
                f"Lean subprocess failed with exit code {returncode}\n"
                f"File: {file_path}\n"
                f"stderr: {stderr_output}"
            )

    def _process_subprocess_output(self, process: subprocess.Popen) -> None:
        """
        Read JSON lines from subprocess stdout and feed to writer.

        Thread-safe: Multiple threads can call this concurrently.

        Args:
            process: subprocess.Popen instance with stdout to read
        """
        if not process.stdout:
            raise RuntimeError("Subprocess stdout is not available")

        # Stream JSON lines and add to writer
        # Writer is thread-safe, so this is safe for parallel execution
        for record in stream_json_lines(process.stdout):
            self.writer.add_record(record)
