# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Lean Scout is a tool for creating datasets from Lean4 projects. It extracts structured data (types, tactics) from Lean code and stores them as sharded Parquet files for dataset creation.

**Key Architecture**: Lean Scout uses a **Python-first bifurcated process model**:
1. Python orchestrator (in `lean_scout.cli`) manages Lean subprocess(es) and coordinates data writing
2. Lean code (in `LeanScout/`) extracts data from Lean environments and outputs JSON lines to stdout
3. Python reads JSON from subprocess stdout and writes to a shared pool of Parquet writers

This design enables **parallel extraction** where multiple Lean processes can run simultaneously while sharing efficient Parquet writers for optimal performance.

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

**Imports target (single subprocess)**:
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

**Read target (parallel subprocesses)**:
```bash
# Extract from single file
lake run scout --command tactics --read MyFile.lean

# Extract from multiple files in parallel (one subprocess per file)
lake run scout --command tactics --read File1.lean File2.lean File3.lean --parallel 4

# Extract from file list (useful for processing entire libraries)
lake build LeanScout:module_paths  # Generates module_paths with all file paths
lake run scout --command tactics --read-list module_paths --parallel 8

# Extract from library using lake query (recommended for libraries)
lake run scout --command tactics --library LeanScoutTest --parallel 8
```

**Key difference**:
- `--imports`: Single Lean subprocess processes entire import closure
- `--read` / `--read-list` / `--library`: One Lean subprocess per file, enabling true parallel extraction

**Note**: `--library` uses the `module_paths` library facet to automatically discover all module files in a library (via `lake query -q <library>:module_paths`). This is more convenient than manually building and passing a file list.

### Testing
```bash
# Run Lean unit tests (schema roundtrip tests)
lake test

# Run all tests (Lean + Python unit tests + integration)
./run_tests

# Run just Python unit tests
uv run pytest test/test_types.py -v

# Run all Python tests
uv run pytest test/ -v
```

**IMPORTANT**: When adding new test files to `test/`, you MUST update the `./run_tests` script to include them in the explicit test file list. This ensures the integration script runs all tests. The script explicitly lists test files rather than using `test/` to provide clear visibility of what's being tested.

Lean Scout has three levels of testing:

1. **Lean Schema Tests** (`lake test`): Tests schema serialization/deserialization roundtrip using `#guard_msgs`
2. **Python Unit Tests** (`pytest`): Tests data extractors against known expected outputs using YAML specifications
3. **Integration Test**: Full end-to-end extraction and validation

#### Adding New Test Cases

To test specific constants from an extractor, edit or create a YAML spec in `test/fixtures/`:

```yaml
# test/fixtures/types_init.yaml
description: "Test types extractor on Init module"
source: "Init"

# Exact matches: verify complete record equality
exact_matches:
  - name: "Nat.add"
    module: "Init.Prelude"
    type: "Nat → Nat → Nat"

# Property checks: verify specific properties
property_checks:
  - name: "List.map"
    properties:
      module_contains: "Init"
      type_contains: "List"
      module_not_null: true

# Count checks: verify dataset statistics
count_checks:
  min_records: 1000
  has_names:
    - "Nat.add"
    - "List.map"
```

The test framework:
- Runs extraction once per test session (efficient)
- Verifies exact matches for critical constants
- Checks properties for flexibility (e.g., substring matching)
- Validates dataset completeness (minimum record counts, required names)

### Python Development
```bash
# Install dependencies
uv sync

# Run Python tests
uv run pytest test/test_types.py -v
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
2. Lake script invokes: `uv run lean-scout --scoutPath <path> --command types --imports Lean`
3. Python CLI (`lean_scout.cli`) parses arguments and queries schema: `lake exe lean_scout --command types --schema`
4. Python creates `ShardedParquetWriter` with the schema and output configuration
5. Python spawns Lean subprocess: `lake exe lean_scout --command types --imports Lean`
6. Lean's `Main.lean` runs the extractor, which outputs JSON lines to stdout
7. Python's `Orchestrator` reads JSON from subprocess stdout and feeds to `ShardedParquetWriter`
8. `ShardedParquetWriter` hashes the key field, batches rows, and writes Parquet files
9. Output: `<dataDir>/<command>/part-NNN.parquet` files (128 shards by default)

### Python Package Structure

The Python code is organized as a proper package:
- `src/lean_scout/`: Main package directory
  - `__init__.py`: Exports public API
  - `cli.py`: Main CLI entry point (orchestrates extraction)
  - `orchestrator.py`: Manages Lean subprocess execution
  - `writer.py`: Thread-safe sharded Parquet writing with batching
  - `utils.py`: Utility functions (schema parsing, JSON streaming)

### Orchestrator

The `Orchestrator` class (in `src/lean_scout/orchestrator.py`) manages Lean subprocess execution:

```python
class Orchestrator:
    def __init__(self, command, scout_path, writer, imports=None, read_file=None, num_workers=1):
        """Initialize with shared writer and extraction parameters."""

    def run(self) -> dict:
        """Spawn Lean subprocess, read JSON output, feed to writer, return stats."""

    def _spawn_lean_subprocess(self) -> subprocess.Popen:
        """Spawn: lake exe lean_scout --command <cmd> --imports/--read <target>"""

    def _process_subprocess_output(self, process):
        """Stream JSON lines from stdout to ShardedParquetWriter."""
```

**Implementation**:
- **Imports target**: Sequential (single Lean subprocess)
- **Read target (multiple files)**: Parallel with `ThreadPoolExecutor`
  - One Lean subprocess spawned per file
  - Controlled by `--parallel N` flag (defaults to min(num_files, num_workers))
  - All subprocesses write to shared thread-safe `ShardedParquetWriter`
  - Progress reporting shows completion status for each file

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

**Thread Safety**: The `ShardedParquetWriter` is thread-safe using a `threading.Lock()` to protect shared state (buffers, writers, counts). This enables future parallel extraction where multiple threads can write to the same writer pool concurrently.

### Lake Configuration

`lakefile.lean` defines:
- `lean_scout` package with experimental module support
- `LeanScout` library (default target)
- `lean_scout` executable (from `Main.lean`)
- `scout` script: wraps `uv run lean-scout` (Python CLI) with `--scoutPath` automatically set to the Scout dependency root
- `module_paths` library facet: generates a file containing all module file paths (one per line), queryable via `lake query -q <library>:module_paths`

**Important**: When Lean Scout is used as a dependency in another project, use `lake run scout` (which invokes the script). The script calls the Python CLI which orchestrates Lean subprocess execution. The `--scoutPath` is automatically passed to ensure correct package resolution.

**Parallel extraction workflow**:
```bash
# Generate list of all module file paths
lake build LeanScout:module_paths

# Extract from all modules in parallel
lake run scout --command tactics --read-list module_paths --parallel 8
```

### Test Infrastructure

The test suite consists of:

1. **Lean Schema Tests** (`LeanScoutTest/Schema.lean`):
   - Uses `#guard_msgs` to test schema JSON serialization/deserialization
   - Validates roundtrip through Python's schema parser
   - Tests all data types: bool, nat, int, float, string, list, struct

2. **Python Unit Tests**:
   - `test/test_types.py`: Tests types extractor with YAML-based specifications
   - `test/test_tactics.py`: Tests tactics extractor with YAML-based specifications
   - `test/test_parallel.py`: Tests parallel file extraction with --read and --read-list
   - `test/test_query_library.py`: Tests --library functionality for library-based extraction
   - `test/test_schema.py`: Tests schema serialization/deserialization
   - Uses pytest framework with YAML-based test specifications
   - Extracts data once per test session (module-scoped fixture)
   - Three types of assertions:
     - **Exact matches**: Full field equality for specific constants
     - **Property checks**: Substring matching and nullability checks
     - **Count checks**: Minimum records and required name existence
   - Helper utilities in `test/helpers.py` for querying datasets

3. **Test Fixtures** (`test/fixtures/*.yaml`):
   - Declarative YAML specifications for expected outputs
   - Easy to read, write, and maintain
   - Version controlled alongside code
   - Example: `types_init.yaml` tests the types extractor on Init module

4. **Integration Script** (`./run_tests`):
   - Runs all Python unit tests sequentially by explicitly listing test files
   - **IMPORTANT**: When adding new test files, update this script to include them
   - Current test files: `test_types.py`, `test_tactics.py`, `test_parallel.py`, `test_query_library.py`, `test_schema.py`
   - Validates full end-to-end pipeline

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
