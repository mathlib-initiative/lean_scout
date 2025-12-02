"""CLI entry point for parquet_writer subprocess."""

import argparse
import logging
import sys

from .utils import deserialize_schema, stream_json_lines
from .writer import ShardedParquetWriter

def main() -> None:
    """Main entry point for parquet_writer subprocess."""
    parser = argparse.ArgumentParser(
        description="Read JSON lines from stdin and write to sharded Parquet files",
    )

    parser.add_argument(
        "--dataDir",
        required=True,
        help="Directory where parquet shards will be saved",
    )
    parser.add_argument(
        "--schema",
        required=True,
        help="JSON schema for the data (PyArrow field definitions)",
    )
    parser.add_argument(
        "--key",
        required=True,
        help="Field name to use as the shard key",
    )
    parser.add_argument(
        "--numShards",
        type=int,
        default=128,
        help="Number of output shards (default: 128)",
    )
    parser.add_argument(
        "--batchRows",
        type=int,
        default=1024,
        help="Rows per batch before flushing (default: 1024)",
    )

    args = parser.parse_args()

    # Deserialize to PyArrow schema
    try:
        pa_schema = deserialize_schema(args.schema)
    except Exception as e:
        sys.exit(1)

    # Create writer
    writer = ShardedParquetWriter(
        schema=pa_schema,
        out_dir=args.dataDir,
        num_shards=args.numShards,
        batch_rows=args.batchRows,
        shard_key=args.key,
    )

    try:
        for record in stream_json_lines(sys.stdin):
            writer.add_record(record)

        print("DONE")
        writer.close()

    except Exception as e:
        writer.close()
        sys.exit(1)


if __name__ == "__main__":
    main()
