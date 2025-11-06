# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Lean Scout is a tool for creating datasets from Lean4 projects. It extracts structured data (types, tactics, subterms) from Lean code and stores them as sharded Parquet files for dataset creation.

**Key Architecture**: Lean Scout uses a **bifurcated process model**:
1. Lean code (in `LeanScout/`) extracts data from Lean environments and writes JSON lines to stdout
2. Python package (`lean_scout`) reads JSON from stdin and writes sharded Parquet files to disk

This design keeps Lean focused on extraction and Python focused on efficient data storage.

## Requirements

- Lean4 installation with `elan`, `lake`, and `lean` (supports `leanprover/lean4:v4.23.0`)
- `uv` Python package manager
- Python 3.13+ with dependencies: `datasets`, `pyarrow`, `pydantic`, `tqdm`

## Common Commands

### Building
```bash
lake build
```

### Running Data Extraction
```bash
# Extract types from Lean standard library
lake run scout --command types --imports Lean

# Extract types from Mathlib (if added as dependency)
lake run scout --command types --imports Mathlib

# Specify custom data directory
lake run scout --command types --dataDir $HOME/storage --imports Mathlib

# Control sharding (default: 128 shards)
lake run scout --command types --numShards 32 --imports Lean
```

### Testing
```bash
# Run Lean unit tests (schema roundtrip tests)
lake test

# Run the integration test (builds, extracts, validates)
./run_tests
```

- `lake test` builds the `LeanScoutTest` library, which includes schema serialization/deserialization tests
- `./run_tests` creates a temporary directory, extracts types from `Init`, and validates the parquet files

### Python Development
```bash
# Install dependencies
uv sync

# Run Python tests
uv run test/test.py <path-to-parquet-directory>
```

### List Available Extractors
```bash
lake run scout --command extractors
```

## Code Architecture

### Data Extractor System

**Core Type**: `DataExtractor` (defined in `LeanScout/Types.lean:70-73`)
```lean
structure DataExtractor where
  schema : Schema      -- Arrow schema defining output structure
  key : String         -- Field name used for computing shard ID
  go : IO.FS.Handle → Target → IO Unit  -- Extraction function
```

**Registration**: Data extractors use the `@[data_extractor cmd]` attribute to register themselves. The attribute system is defined in `LeanScout/Init.lean:17-42` using a `PersistentEnvExtension` that maintains a `HashMap` of command names to extractor implementations.

**Discovery**: The `data_extractors` elaborator (in `LeanScout/Init.lean:45-52`) generates a compile-time HashMap of all registered extractors by querying the environment extension.

### Existing Extractors

Located in `LeanScout/DataExtractors/`:
- **types**: Extracts constant names, modules, and types from Lean environments
- **tactics**: Extracts tactic usage information
- **subterms**: Extracts subterm structures from expressions

### Target System

`Target` (defined in `LeanScout/Types.lean:45-47`) represents what to extract from:
- `.imports`: Load specific modules and extract from the resulting environment
- `.input`: Read a Lean file and extract from it

### Schema System

Schema definition uses a custom Arrow-compatible type system:
- Types: `bool`, `nat`, `int`, `string`, `float`, `list`, `struct`
- Fields have: `name`, `type`, `nullable` flag
- Schemas serialize to JSON and are passed to the Python subprocess

**JSON serialization** (in `LeanScout/Schema.lean`) handles bidirectional conversion between Lean's schema representation and JSON format consumed by the Python package.

### Data Flow

1. User runs: `lake run scout --command types --imports Lean`
2. `Main.lean` parses arguments and builds `Options`
3. Main spawns `uv run python -m lean_scout` subprocess with schema JSON, shard config, and base path
4. Extractor's `go` function writes JSON lines to subprocess stdin
5. Python package deserializes JSON, hashes the key field to compute shard, batches rows, and writes Parquet files
6. Output: `<dataDir>/<command>/part-NNN.parquet` files (128 shards by default)

### Python Package Structure

The Python code is organized as a proper package:
- `src/lean_scout/`: Main package directory
  - `__init__.py`: Exports public API
  - `utils.py`: Utility functions (schema parsing, JSON streaming)
  - `writer.py`: Sharded Parquet writing with batching
  - `__main__.py`: CLI entry point

### Sharding Strategy

Sharding uses BLAKE2b hashing of the key field. The `ShardedParquetWriter._compute_shard()` private method (in `src/lean_scout/writer.py`) computes the shard assignment:
```python
def _compute_shard(self, value: Any) -> int:
    """Hash a value to determine its shard. Converts to string if needed."""
    if isinstance(value, str):
        s = value
    else:
        s = json.dumps(value, sort_keys=True)
    h = hashlib.blake2b(s.encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") % self.num_shards
```

The key field is specified per extractor (e.g., `types` uses `"name"` as the key).

### Lake Configuration

`lakefile.lean` defines:
- `lean_scout` package with experimental module support
- `LeanScout` library (default target)
- `lean_scout` executable (from `Main.lean`)
- `scout` script: wraps `lake exe lean_scout` with `--scoutPath` automatically set to the Scout dependency root

**Important**: When Lean Scout is used as a dependency in another project, use `lake run scout` (which invokes the script), not `lake exe lean_scout` directly. The script ensures the correct `--scoutPath` is passed.

## Adding a New Data Extractor

1. Create a new file in `LeanScout/DataExtractors/` (e.g., `MyExtractor.lean`)
2. Import required modules and define your extractor:
   ```lean
   @[data_extractor mycommand]
   public unsafe def myExtractor : DataExtractor where
     schema := .mk [
       { name := "id", nullable := false, type := .string },
       { name := "data", nullable := true, type := .string }
     ]
     key := "id"
     go handle
     | .imports tgt => tgt.runCoreM <| Meta.MetaM.run' do
       -- Your extraction logic here
       handle.putStrLn <| Json.compress <| json% { id : "...", data : "..." }
     | _ => throw <| .userError "Unsupported Target"
   ```
3. Import in `LeanScout/DataExtractors.lean`
4. Rebuild and run: `lake run scout --command mycommand --imports Lean`

## Python Dataset Creation

After extraction, load datasets using:
```python
from datasets import Dataset
import glob

dataset = Dataset.from_parquet(glob.glob("types/*.parquet"))
```

Or:
```python
from datasets import load_dataset

dataset = load_dataset("parquet", data_dir="types", split="train")
```
