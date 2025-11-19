"""Tests for ShardedParquetWriter infrastructure.

This module tests the writer's core functionality without extracting Lean data.
Tests focus on:
- Sharding logic (BLAKE2b hashing)
- Thread safety
- Batching behavior
- File creation and statistics
"""
import pytest
import tempfile
import threading
from pathlib import Path
from typing import cast, Any
from datasets import Dataset
import glob
import pyarrow as pa

from lean_scout.writer import ShardedParquetWriter


@pytest.fixture
def simple_schema():

    return pa.schema([
        pa.field("name", pa.string(), nullable=False),
        pa.field("value", pa.int64(), nullable=True),
    ])


@pytest.fixture
def writer_dir():

    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


def test_writer_basic_add_and_close(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=4,
        batch_rows=10,
        shard_key="name",
    )

    # Add some records
    records = [
        {"name": "foo", "value": 1},
        {"name": "bar", "value": 2},
        {"name": "baz", "value": 3},
    ]

    for record in records:
        writer.add_record(record)

    # Close and get stats
    stats = writer.close()

    assert stats["total_rows"] == 3
    assert stats["num_shards"] > 0
    assert stats["out_dir"] == str(writer_dir)


def test_writer_sharding_deterministic(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=8,
        batch_rows=10,
        shard_key="name",
    )

    # Same name should always go to same shard
    test_name = "test_constant"

    # Compute shard for test name
    shard1 = writer._compute_shard(test_name)
    shard2 = writer._compute_shard(test_name)

    assert shard1 == shard2, "Sharding should be deterministic"
    assert 0 <= shard1 < 8, "Shard should be in valid range"

    writer.close()


def test_writer_batching(simple_schema, writer_dir):
    batch_size = 5
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=2,
        batch_rows=batch_size,
        shard_key="name",
    )

    # Add records all to same shard (same name)
    for i in range(batch_size + 2):
        writer.add_record({"name": "same_shard", "value": i})

    # After batch_size records, should have flushed once
    # Buffer should have 2 records remaining
    shard = writer._compute_shard("same_shard")
    assert len(writer.buffers[shard]) == 2, "Buffer should have 2 remaining records after batch flush"

    stats = writer.close()
    assert stats["total_rows"] == batch_size + 2


def test_writer_multiple_shards(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=4,
        batch_rows=10,
        shard_key="name",
    )

    # Add records with different names to hit different shards
    names = [f"name_{i}" for i in range(20)]
    for name in names:
        writer.add_record({"name": name, "value": 1})

    stats = writer.close()

    # Should have created multiple shard files
    parquet_files = glob.glob(str(writer_dir / "*.parquet"))
    assert len(parquet_files) > 1, "Should create multiple shard files"
    assert stats["total_rows"] == 20


def test_writer_thread_safety(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=8,
        batch_rows=50,
        shard_key="name",
    )

    num_threads = 4
    records_per_thread = 100

    def write_records(thread_id):
        for i in range(records_per_thread):
            writer.add_record({
                "name": f"thread_{thread_id}_record_{i}",
                "value": i
            })

    # Launch threads
    threads = []
    for tid in range(num_threads):
        t = threading.Thread(target=write_records, args=(tid,))
        threads.append(t)
        t.start()

    # Wait for all threads
    for t in threads:
        t.join()

    # Close and verify
    stats = writer.close()
    expected_total = num_threads * records_per_thread
    assert stats["total_rows"] == expected_total, \
        f"Should have {expected_total} total rows from {num_threads} threads"


def test_writer_flush_all(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=4,
        batch_rows=100,  # Large batch so auto-flush doesn't trigger
        shard_key="name",
    )

    # Add a few records (less than batch_rows)
    for i in range(10):
        writer.add_record({"name": f"record_{i}", "value": i})

    # Manually flush
    writer.flush_all()

    # All buffers should be empty
    for shard, buffer in writer.buffers.items():
        assert len(buffer) == 0, f"Buffer for shard {shard} should be empty after flush_all"

    stats = writer.close()
    assert stats["total_rows"] == 10


def test_writer_output_files_valid(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=4,
        batch_rows=10,
        shard_key="name",
    )

    # Add test data
    test_data = [
        {"name": "alice", "value": 10},
        {"name": "bob", "value": 20},
        {"name": "charlie", "value": 30},
    ]

    for record in test_data:
        writer.add_record(record)

    writer.close()

    # Verify we can load the parquet files
    parquet_paths = list(writer_dir.glob("*.parquet"))
    assert len(parquet_paths) > 0, "Should create parquet files"

    # Load and verify data
    dataset = cast(Dataset, Dataset.from_parquet([str(p) for p in parquet_paths]))
    assert len(dataset) == len(test_data), "Should have all records in dataset"

    # Verify schema
    column_names = dataset.column_names
    assert column_names is not None
    assert "name" in column_names
    assert "value" in column_names


def test_writer_nullable_fields(writer_dir):
    schema = pa.schema([
        pa.field("name", pa.string(), nullable=False),
        pa.field("optional_value", pa.int64(), nullable=True),
    ])

    writer = ShardedParquetWriter(
        schema=schema,
        out_dir=str(writer_dir),
        num_shards=2,
        batch_rows=10,
        shard_key="name",
    )

    # Add records with None values
    writer.add_record({"name": "foo", "optional_value": 10})
    writer.add_record({"name": "bar", "optional_value": None})

    stats = writer.close()
    assert stats["total_rows"] == 2

    # Verify nullable fields in output
    parquet_paths = list(writer_dir.glob("*.parquet"))
    dataset = cast(Dataset, Dataset.from_parquet([str(p) for p in parquet_paths]))
    records: list[dict[str, Any]] = [dict(record) for record in dataset]

    # Find the record with None value
    none_record = next(r for r in records if r["name"] == "bar")
    assert none_record["optional_value"] is None


def test_writer_shard_key_nullable():
    with tempfile.TemporaryDirectory() as tmpdir:
        schema = pa.schema([
            pa.field("name", pa.string(), nullable=True),  # Nullable shard key
            pa.field("value", pa.int64(), nullable=True),
        ])

        writer = ShardedParquetWriter(
            schema=schema,
            out_dir=tmpdir,
            num_shards=4,
            batch_rows=10,
            shard_key="name",
        )

        # Record with shard key
        writer.add_record({"name": "foo", "value": 1})

        # Record with missing/None shard key
        writer.add_record({"name": None, "value": 2})

        stats = writer.close()
        assert stats["total_rows"] == 2


def test_writer_empty_close(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=4,
        batch_rows=10,
        shard_key="name",
    )

    # Close without adding any records
    stats = writer.close()

    assert stats["total_rows"] == 0
    assert stats["num_shards"] == 0


def test_writer_compression(simple_schema, writer_dir):
    writer = ShardedParquetWriter(
        schema=simple_schema,
        out_dir=str(writer_dir),
        num_shards=2,
        batch_rows=10,
        shard_key="name",
        compression="snappy"  # Use snappy instead of default zstd
    )

    # Add some records
    for i in range(20):
        writer.add_record({"name": f"record_{i}", "value": i})

    writer.close()

    # Verify files were created
    parquet_files = glob.glob(str(writer_dir / "*.parquet"))
    assert len(parquet_files) > 0
