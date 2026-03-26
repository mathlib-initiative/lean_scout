"""Tests for parquet_writer CLI."""

import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

import pyarrow.parquet as pq
import pytest

from lean_scout.cli import main


class TestParquetWriterCliUnit:
    """Unit tests for parquet_writer CLI (in-process, for coverage)."""

    def test_main_basic_write(self):
        """Test basic JSON to Parquet conversion via main()."""
        schema = {
            "fields": [
                {"name": "name", "nullable": False, "type": {"datatype": "string"}},
                {"name": "value", "type": {"datatype": "int"}},
            ]
        }

        records = [
            {"name": "alpha", "value": 1},
            {"name": "beta", "value": 2},
        ]
        input_data = "\n".join(json.dumps(r) for r in records)

        with tempfile.TemporaryDirectory() as tmpdir:
            test_args = [
                "parquet_writer",
                "--dataDir", tmpdir,
                "--schema", json.dumps(schema),
                "--key", "name",
                "--numShards", "2",
            ]

            with (
                mock.patch.object(sys, "argv", test_args),
                mock.patch.object(sys, "stdin", io.StringIO(input_data)),
            ):
                main()

            parquet_files = list(Path(tmpdir).glob("*.parquet"))
            assert len(parquet_files) > 0

            total_rows = sum(pq.read_table(pf).num_rows for pf in parquet_files)
            assert total_rows == 2

    def test_main_invalid_schema_exits(self):
        """Test that invalid schema causes exit."""
        with tempfile.TemporaryDirectory() as tmpdir:
            test_args = [
                "parquet_writer",
                "--dataDir", tmpdir,
                "--schema", "not valid json",
                "--key", "name",
            ]

            with (
                mock.patch.object(sys, "argv", test_args),
                pytest.raises(SystemExit) as exc_info,
            ):
                main()

            assert exc_info.value.code == 1

    def test_main_with_custom_batch_rows(self):
        """Test --batchRows option."""
        schema = {
            "fields": [
                {"name": "x", "type": {"datatype": "int"}},
            ]
        }

        records = [{"x": i} for i in range(5)]
        input_data = "\n".join(json.dumps(r) for r in records)

        with tempfile.TemporaryDirectory() as tmpdir:
            test_args = [
                "parquet_writer",
                "--dataDir", tmpdir,
                "--schema", json.dumps(schema),
                "--key", "x",
                "--batchRows", "2",
            ]

            with (
                mock.patch.object(sys, "argv", test_args),
                mock.patch.object(sys, "stdin", io.StringIO(input_data)),
            ):
                main()

            parquet_files = list(Path(tmpdir).glob("*.parquet"))
            total_rows = sum(pq.read_table(pf).num_rows for pf in parquet_files)
            assert total_rows == 5

    def test_main_exception_during_processing_exits(self):
        """Test that exceptions during processing cause exit."""
        schema = {
            "fields": [
                {"name": "name", "type": {"datatype": "string"}},
            ]
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            test_args = [
                "parquet_writer",
                "--dataDir", tmpdir,
                "--schema", json.dumps(schema),
                "--key", "name",
            ]

            mock_stdin = mock.MagicMock()
            mock_stdin.__iter__ = mock.MagicMock(side_effect=RuntimeError("test error"))

            with (
                mock.patch.object(sys, "argv", test_args),
                mock.patch.object(sys, "stdin", mock_stdin),
                pytest.raises(SystemExit) as exc_info,
            ):
                main()

            assert exc_info.value.code == 1

    def test_main_keyboard_interrupt_exits_130(self):
        """Test that KeyboardInterrupt causes exit code 130."""
        schema = {
            "fields": [
                {"name": "name", "type": {"datatype": "string"}},
            ]
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            test_args = [
                "parquet_writer",
                "--dataDir", tmpdir,
                "--schema", json.dumps(schema),
                "--key", "name",
            ]

            mock_stdin = mock.MagicMock()
            mock_stdin.__iter__ = mock.MagicMock(side_effect=KeyboardInterrupt())

            with (
                mock.patch.object(sys, "argv", test_args),
                mock.patch.object(sys, "stdin", mock_stdin),
                pytest.raises(SystemExit) as exc_info,
            ):
                main()

            assert exc_info.value.code == 130

    def test_main_malformed_json_exits(self):
        """Test that malformed JSON is fatal."""
        schema = {
            "fields": [
                {"name": "name", "type": {"datatype": "string"}},
            ]
        }

        input_data = '{"name": "ok"}\nnot valid json\n'

        with tempfile.TemporaryDirectory() as tmpdir:
            test_args = [
                "parquet_writer",
                "--dataDir", tmpdir,
                "--schema", json.dumps(schema),
                "--key", "name",
            ]

            with (
                mock.patch.object(sys, "argv", test_args),
                mock.patch.object(sys, "stdin", io.StringIO(input_data)),
                pytest.raises(SystemExit) as exc_info,
            ):
                main()

            assert exc_info.value.code == 1


class TestParquetWriterCliSubprocess:
    """Integration tests for parquet_writer CLI (subprocess)."""

    def test_basic_write(self):
        """Test basic JSON to Parquet conversion via subprocess."""
        schema = {
            "fields": [
                {"name": "name", "nullable": False, "type": {"datatype": "string"}},
                {"name": "value", "type": {"datatype": "int"}},
            ]
        }

        records = [
            {"name": "alpha", "value": 1},
            {"name": "beta", "value": 2},
            {"name": "gamma", "value": 3},
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            input_data = "\n".join(json.dumps(r) for r in records)

            result = subprocess.run(
                [
                    "uv", "run", "parquet_writer",
                    "--dataDir", tmpdir,
                    "--schema", json.dumps(schema),
                    "--key", "name",
                    "--numShards", "4",
                ],
                input=input_data,
                capture_output=True,
                text=True,
            )

            assert result.returncode == 0

            parquet_files = list(Path(tmpdir).glob("*.parquet"))
            assert len(parquet_files) > 0

            total_rows = sum(pq.read_table(pf).num_rows for pf in parquet_files)
            assert total_rows == 3

    def test_missing_required_args(self):
        """Test that missing required arguments causes error."""
        result = subprocess.run(
            ["uv", "run", "parquet_writer"],
            capture_output=True,
            text=True,
        )

        assert result.returncode != 0
        assert "required" in result.stderr.lower()

    def test_malformed_json_is_fatal(self):
        """Test that malformed JSON causes a nonzero exit."""
        schema = {
            "fields": [
                {"name": "name", "nullable": False, "type": {"datatype": "string"}},
            ]
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "uv", "run", "parquet_writer",
                    "--dataDir", tmpdir,
                    "--schema", json.dumps(schema),
                    "--key", "name",
                ],
                input='{"name": "ok"}\nnot valid json\n',
                capture_output=True,
                text=True,
            )

            assert result.returncode == 1

    def test_processing_failure_does_not_report_secondary_close_error(self):
        """Test that cleanup does not mask the primary writer failure."""
        schema = {
            "fields": [
                {"name": "name", "nullable": False, "type": {"datatype": "string"}},
            ]
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "uv", "run", "parquet_writer",
                    "--dataDir", tmpdir,
                    "--schema", json.dumps(schema),
                    "--key", "name",
                ],
                input='{}\n',
                capture_output=True,
                text=True,
            )

            assert result.returncode == 1
            assert "Operation on closed file" not in result.stderr
