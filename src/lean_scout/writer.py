import json
import os
import hashlib
import threading
from typing import Any
import pyarrow as pa
import pyarrow.parquet as pq


class ShardedParquetWriter:
    """Manages sharded parquet file writing with batching."""

    def __init__(
        self,
        schema: pa.Schema,
        out_dir: str,
        num_shards: int,
        batch_rows: int,
        shard_key: str,
        compression: str = "zstd"
    ):
        self.schema = schema
        self.out_dir = out_dir
        self.num_shards = num_shards
        self.batch_rows = batch_rows
        self.shard_key = shard_key
        self.compression = compression

        self.writers = {}   # shard -> pq.ParquetWriter (opened lazily)
        self.buffers = {}   # shard -> []
        self.counts = {}    # shard -> total rows written

        self._lock = threading.Lock()

        os.makedirs(self.out_dir, exist_ok=True)

    def _compute_shard(self, value: Any) -> int:
        """Hash a value to determine its shard. Converts to string if needed."""
        if isinstance(value, str):
            s = value
        else:
            s = json.dumps(value, sort_keys=True)
        h = hashlib.blake2b(s.encode("utf-8"), digest_size=8).digest()
        return int.from_bytes(h, "big") % self.num_shards

    def add_record(self, record: dict) -> None:
        """Add a record to the appropriate shard buffer, flushing if needed."""

        shard_key_value = record.get(self.shard_key)
        shard = self._compute_shard(shard_key_value)

        with self._lock:
            buffer = self.buffers.setdefault(shard, [])
            buffer.append(record)

            if len(buffer) >= self.batch_rows:
                self._flush_shard_unsafe(shard)

    def _flush_shard_unsafe(self, shard: int) -> None:
        """Flush a specific shard's buffer to disk (internal, no locking).

        Must be called while holding self._lock.
        """
        records = self.buffers.get(shard)
        if not records:
            return

        if shard not in self.writers:
            path = os.path.join(self.out_dir, f"part-{shard:03d}.parquet")
            self.writers[shard] = pq.ParquetWriter(path, self.schema, compression=self.compression)
            self.counts[shard] = 0

        table = pa.Table.from_pylist(records, schema=self.schema)
        self.writers[shard].write_table(table)
        self.counts[shard] += table.num_rows

        records.clear()

    def flush_shard(self, shard: int) -> None:
        """Flush a specific shard's buffer to disk."""
        with self._lock:
            self._flush_shard_unsafe(shard)

    def flush_all(self) -> None:
        """Flush all shard buffers to disk."""
        with self._lock:
            for shard in list(self.buffers.keys()):
                self._flush_shard_unsafe(shard)

    def close(self) -> dict:
        """Close all writers and return statistics.

        Should only be called once, after all records have been added.
        """
        with self._lock:

            for shard in list(self.buffers.keys()):
                self._flush_shard_unsafe(shard)

            for writer in self.writers.values():
                writer.close()

            return {
                "total_rows": sum(self.counts.values()) if self.counts else 0,
                "num_shards": len(self.writers),
                "out_dir": self.out_dir
            }
