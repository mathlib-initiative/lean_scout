"""Tests for Orchestrator infrastructure.

This module tests the orchestrator's core functionality without extracting Lean data.
Tests focus on:
- Initialization validation
- Output parsing
- Error handling
"""
import pytest
import tempfile
from pathlib import Path
from io import StringIO
import pyarrow as pa

from lean_scout.orchestrator import Orchestrator
from lean_scout.writer import ShardedParquetWriter


class FakeProcess:
    def __init__(self, stdout):
        self.stdout = stdout


@pytest.fixture
def simple_schema():
    return pa.schema([
        pa.field("name", pa.string(), nullable=False),
        pa.field("value", pa.int64(), nullable=True),
    ])


@pytest.fixture
def writer(simple_schema):
    with tempfile.TemporaryDirectory() as tmpdir:
        writer = ShardedParquetWriter(
            schema=simple_schema,
            out_dir=tmpdir,
            num_shards=4,
            batch_rows=10,
            shard_key="name",
        )
        yield writer


@pytest.fixture
def root_path():
    return Path.cwd()


def test_orchestrator_init_validation_both_targets(writer, root_path):
    with pytest.raises(ValueError, match="Cannot specify both"):
        Orchestrator(
            command="types",
            root_path=root_path,
            writer=writer,
            imports=["Lean"],
            read_files=["File.lean"],
        )


def test_orchestrator_init_validation_no_targets(writer, root_path):
    with pytest.raises(ValueError, match="Must specify either"):
        Orchestrator(
            command="types",
            root_path=root_path,
            writer=writer,
        )


def test_orchestrator_init_valid_imports(writer, root_path):
    orch = Orchestrator(
        command="types",
        root_path=root_path,
        writer=writer,
        imports=["Lean", "Init"],
    )

    assert orch.command == "types"
    assert orch.imports == ["Lean", "Init"]
    assert orch.read_files is None


def test_orchestrator_init_valid_read(writer, root_path):
    orch = Orchestrator(
        command="tactics",
        root_path=root_path,
        writer=writer,
        read_files=["File1.lean", "File2.lean"],
        num_workers=4,
    )

    assert orch.command == "tactics"
    assert orch.read_files == ["File1.lean", "File2.lean"]
    assert orch.imports is None
    assert orch.num_workers == 4


def test_orchestrator_process_output_valid_json(writer, root_path):
    orch = Orchestrator(
        command="types",
        root_path=root_path,
        writer=writer,
        imports=["Lean"],
    )

    stdout = StringIO('{"name": "foo", "value": 1}\n{"name": "bar", "value": 2}\n')
    process = FakeProcess(stdout)

    orch._process_subprocess_output(process)

    stats = writer.close()
    assert stats["total_rows"] == 2


def test_orchestrator_process_output_empty(writer, root_path):
    orch = Orchestrator(
        command="types",
        root_path=root_path,
        writer=writer,
        imports=["Lean"],
    )

    stdout = StringIO('')
    process = FakeProcess(stdout)

    orch._process_subprocess_output(process)

    stats = writer.close()
    assert stats["total_rows"] == 0


def test_orchestrator_process_output_no_stdout(writer, root_path):
    orch = Orchestrator(
        command="types",
        root_path=root_path,
        writer=writer,
        imports=["Lean"],
    )

    process = FakeProcess(None)

    with pytest.raises(RuntimeError, match="stdout is not available"):
        orch._process_subprocess_output(process)
