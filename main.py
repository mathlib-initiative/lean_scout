#!/usr/bin/env python3
import sys
import json
import os
import hashlib
import argparse
from tqdm import tqdm
from typing import Iterator, Optional, Any
import pyarrow as pa
import pyarrow.parquet as pq

def datatype_from_json(type_obj : dict, children=None):
    name = type_obj.get("name")
    if name == "bool":
        return pa.bool_()
    elif name == "uint64":
        return pa.uint64()
    elif name == "int64":
        return pa.int64()
    elif name == "float64":
        return pa.float64()
    elif name == "string":
        return pa.string()
    elif name == "list":
        if children and len(children) > 0:
            item_field = field_from_json(children[0])
            return pa.list_(item_field)
        else:
            raise ValueError("List type must have children")
    elif name == "struct":
        if children:
            fields = [field_from_json(child) for child in children]
            return pa.struct(fields)
        else:
            return pa.struct([])

def field_from_json(field_obj : dict):
    name = field_obj.get("name")
    nullable = field_obj.get("nullable", True)
    type_obj = field_obj.get("type", {})
    children = field_obj.get("children", None)
    datatype = datatype_from_json(type_obj, children)
    return pa.field(name, datatype, nullable=nullable)

def schema_from_json(schema_obj : dict):
    fields = [field_from_json(field) for field in schema_obj.get("fields", [])]
    return pa.schema(fields)

def deserialize_schema(json_str : str):
    schema_obj = json.loads(json_str)
    return schema_from_json(schema_obj)

def load_schema(schema_str: Optional[str] = None, schema_file: Optional[str] = None) -> pa.Schema:
    """Load PyArrow schema from pandas-compatible JSON string or file."""
    schema_json = None
    if schema_str:
        schema_json = schema_str
    elif schema_file:
        with open(schema_file, 'r') as f:
            schema_json = f.read()
    else:
        raise ValueError("Either --schema or --schema-file must be provided")

    return deserialize_schema(schema_json)

def stream_json_lines(input_stream) -> Iterator[dict]:
    """Stream and parse JSON lines from input, skipping malformed lines."""
    for line in input_stream:
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue  # skip malformed lines

def compute_shard(value: Any, num_shards: int) -> int:
    """Hash a value to determine its shard. Converts to string if needed."""
    if isinstance(value, str):
        s = value
    else:
        s = json.dumps(value, sort_keys=True)
    h = hashlib.blake2b(s.encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") % num_shards

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

        os.makedirs(self.out_dir, exist_ok=True)

    def add_record(self, record: dict) -> None:
        """Add a record to the appropriate shard buffer, flushing if needed."""
        # Get shard key value
        shard_key_value = record.get(self.shard_key)

        shard = compute_shard(shard_key_value, self.num_shards)
        buffer = self.buffers.setdefault(shard, [])

        # Append values
        buffer.append(record)

        # Check if buffer is full
        if len(buffer) >= self.batch_rows:
            self.flush_shard(shard)

    def flush_shard(self, shard: int) -> None:
        """Flush a specific shard's buffer to disk."""
        records = self.buffers.get(shard)
        if not records:
            return

        # Open writer lazily
        if shard not in self.writers:
            path = os.path.join(self.out_dir, f"part-{shard:03d}.parquet")
            self.writers[shard] = pq.ParquetWriter(path, self.schema, compression=self.compression)
            self.counts[shard] = 0
        
        # Let PyArrow handle nested structs automatically
        table = pa.Table.from_pylist(records, schema=self.schema)
        self.writers[shard].write_table(table)
        self.counts[shard] += table.num_rows

        records.clear()

    def flush_all(self) -> None:
        """Flush all shard buffers to disk."""
        for shard in list(self.buffers.keys()):
            self.flush_shard(shard)

    def close(self) -> dict:
        """Close all writers and return statistics."""
        self.flush_all()

        for writer in self.writers.values():
            writer.close()

        return {
            "total_rows": sum(self.counts.values()) if self.counts else 0,
            "num_shards": len(self.writers),
            "out_dir": self.out_dir
        }

def main():
    parser = argparse.ArgumentParser(description="Stream JSON lines to sharded Parquet files")
    parser.add_argument("--schema", type=str, help="PyArrow schema as JSON line")
    parser.add_argument("--schema-file", type=str, help="Path to file containing PyArrow schema JSON")
    parser.add_argument("--key", type=str, required=True, help="Field name to use for sharding")
    parser.add_argument("--numShards", type=int, default=128, help="Number of shard files (default: 128)")
    parser.add_argument("--batchRows", type=int, default=1024, help="Rows per batch before flushing (default: 1024)")
    parser.add_argument("--basePath", type=str, required=True, help="Base output directory path")
    args = parser.parse_args()

    schema = load_schema(args.schema, args.schema_file)

    writer = ShardedParquetWriter(
        schema=schema,
        out_dir=args.basePath,
        num_shards=args.numShards,
        batch_rows=args.batchRows,
        shard_key=args.key
    )

    for record in tqdm(stream_json_lines(sys.stdin), file=sys.stderr, desc="Processing records"):
        writer.add_record(record)

    stats = writer.close()

    sys.stderr.write(f"Wrote {stats['total_rows']} rows into {stats['num_shards']} shard files under {stats['out_dir']}\n")

if __name__ == "__main__":
    main()