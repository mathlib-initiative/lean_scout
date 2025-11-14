"""CLI entry point for the parquet writer."""
import sys
import argparse
from tqdm import tqdm

from .utils import load_schema, stream_json_lines
from .writer import ShardedParquetWriter

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
