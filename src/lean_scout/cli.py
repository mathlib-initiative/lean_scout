"""CLI entry point for parquet_writer subprocess."""

import argparse
import sys
from contextlib import suppress

from .parquet_writer import ShardedParquetWriter
from .utils import deserialize_schema, stream_json_lines


def _best_effort_close(writer: ShardedParquetWriter | None) -> None:
    """Attempt to close the writer without masking a primary failure."""
    if writer is None:
        return
    with suppress(Exception):
        writer.close()


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

    try:
        pa_schema = deserialize_schema(args.schema)
    except Exception:
        sys.exit(1)

    writer = ShardedParquetWriter(
        schema=pa_schema,
        out_dir=args.dataDir,
        num_shards=args.numShards,
        batch_rows=args.batchRows,
        shard_key=args.key,
    )

    completed = False
    try:
        for record in stream_json_lines(sys.stdin):
            writer.add_record(record)

        writer.close()
        completed = True
    except KeyboardInterrupt:
        if not completed:
            _best_effort_close(writer)
        sys.exit(130)
    except Exception:
        if not completed:
            _best_effort_close(writer)
        sys.exit(1)


if __name__ == "__main__":  # pragma: no cover
    main()
