import hashlib
import json
import os
import threading
from contextlib import suppress
from typing import Any

import pyarrow as pa  # type: ignore[import-untyped]
import pyarrow.parquet as pq  # type: ignore[import-untyped]


class ShardedParquetWriter:
    """Manages sharded parquet file writing with batching."""

    def __init__(
        self,
        schema: pa.Schema,
        out_dir: str,
        num_shards: int,
        batch_rows: int,
        shard_key: str,
        compression: str = "zstd",
    ) -> None:
        self.schema = schema
        self.out_dir = out_dir
        self.num_shards = num_shards
        self.batch_rows = batch_rows
        self.shard_key = shard_key
        self.compression = compression

        self.writers: dict[int, pq.ParquetWriter] = {}  # shard -> pq.ParquetWriter (opened lazily)
        self.buffers: dict[int, list[dict[str, Any]]] = {}  # shard -> []
        self.counts: dict[int, int] = {}  # shard -> total rows written
        self.paths: dict[int, str] = {}  # shard -> file path

        self._lock = threading.Lock()
        self._closed = False
        self._close_stats: dict[str, int | str] | None = None

        os.makedirs(self.out_dir, exist_ok=True)

    def _compute_shard(self, value: Any) -> int:
        """Hash a value to determine its shard. Converts to string if needed."""
        s = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
        h = hashlib.blake2b(s.encode("utf-8"), digest_size=8).digest()
        return int.from_bytes(h, "big") % self.num_shards

    def _current_stats(self) -> dict[str, int | str]:
        """Return current writer statistics."""
        return {
            "total_rows": sum(self.counts.values()) if self.counts else 0,
            "num_shards": len(self.writers),
            "out_dir": self.out_dir,
        }

    def add_record(self, record: dict[str, Any]) -> None:
        """Add a record to the appropriate shard buffer, flushing if needed."""
        if self._closed:
            raise RuntimeError("cannot add records after writer has been closed")

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
            self.paths[shard] = path

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

    def _close_open_writers_unsafe(self) -> None:
        """Best-effort close of all open shard writers.

        Must be called while holding self._lock.
        """
        for writer in self.writers.values():
            with suppress(Exception):
                writer.close()

    def close(self) -> dict[str, int | str]:
        """Close all writers and return statistics.

        The method is idempotent. If a previous close attempt failed, later calls return the
        best-known statistics instead of raising a secondary cleanup error.
        """
        with self._lock:
            if self._closed:
                return self._close_stats or self._current_stats()

            writers_closed_cleanly = False
            try:
                for shard in list(self.buffers.keys()):
                    self._flush_shard_unsafe(shard)

                for writer in self.writers.values():
                    writer.close()
                writers_closed_cleanly = True

                self._close_stats = self._current_stats()
                return self._close_stats
            finally:
                self._closed = True
                if not writers_closed_cleanly:
                    self._close_open_writers_unsafe()
