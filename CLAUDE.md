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
# Run all tests (all three phases)
./run_tests

# Run individual phases
lake test                          # Phase 0: Lean schema tests
uv run pytest test/internals/ -v  # Phase 1: Infrastructure tests
uv run pytest test/extractors/ -v # Phase 2: Extractor tests
```

Lean Scout has a **three-phase test architecture**:

**Phase 0: Lean Schema Tests** (`lake test`)
- Tests schema serialization/deserialization roundtrip in Lean
- Located in `LeanScoutTest.lean`
- Uses `#guard_msgs` to verify schema JSON format
- Ensures Lean schemas can be correctly parsed by Python

**Phase 1: Infrastructure Tests** (`test/internals/`)
- Tests Python infrastructure without extracting Lean data
- Focus: Schema querying, writer logic, orchestrator, CLI utilities
- Tests use real subprocess calls (no mocking)
- Files: `test_schema.py`, `test_writer.py`, `test_orchestrator.py`, `test_cli.py`
- 34 tests, fast execution

**Phase 2: Data Extractor Tests** (`test/extractors/`)
- Tests data extractors using `test_project` as dependency
- Focus: Verifying extractors produce correct output
- Uses YAML-based specifications for expected outputs
- Files: `test_types.py`, `test_tactics.py`
- 17 tests

#### Test Project

The `test_project/` directory contains a minimal Lean project used for testing:
- Simple theorems in `Basic.lean` and `Lists.lean`
- Lean Scout is added as a dependency
- Tests verify extractors work correctly when Scout is used as a dependency

#### Adding New Test Cases

To test specific constants from an extractor, edit or create a YAML spec in `test/fixtures/`:

```yaml
# test/fixtures/types.yaml
exact_matches:
  - name: "Nat.add"
    module: "LeanScoutTestProject.Basic"
    type: "Nat → Nat → Nat"

property_checks:
  - name: "List.length"
    properties:
      module_contains: "LeanScoutTestProject"
      type_contains: "List"

count_checks:
  min_records: 100
  has_names:
    - "Nat.add"
    - "List.length"
```

The test framework:
- Extracts data once per test session (efficient)
- Verifies exact matches for critical constants
- Checks properties for flexibility (substring matching)
- Validates dataset completeness (minimum records, required names)

### Python Development
```bash
# Install dependencies
uv sync

# Run infrastructure tests
uv run pytest test/internals/ -v

# Run extractor tests
uv run pytest test/extractors/ -v
```

### List Available Extractors
```bash
lake run scout --command extractors
```

## Code Architecture

### Data Extractor System

**Core Type**: `DataExtractor` (defined in `LeanScout/Types.lean`)
```lean
structure DataExtractor where
  schema : Schema      -- Arrow schema defining output structure
  key : String         -- Field name used for computing shard ID
  go : (Json → IO Unit) → Target → IO Unit  -- Extraction function
```

The `go` function takes:
- A `sink` function (`Json → IO Unit`) for writing JSON records
- A `Target` specifying what to extract from (`.imports` or `.input`)
- Extracts data and writes JSON records by calling the sink

**Registration**: Data extractors use the `@[data_extractor cmd]` attribute to register themselves. The attribute system is defined in `LeanScout/Init.lean:17-42` using a `PersistentEnvExtension` that maintains a `HashMap` of command names to extractor implementations.

**Discovery**: The `data_extractors` elaborator (in `LeanScout/Init.lean:45-52`) generates a compile-time HashMap of all registered extractors by querying the environment extension.

### Existing Extractors

Located in `LeanScout/DataExtractors/`:
- **types**: Extracts constant names, modules, and types from Lean environments
- **tactics**: Extracts tactic invocations with:
  - Goal states before the tactic (pretty-printed goals and used constants)
  - Pretty-printed tactic syntax
  - Elaborator name
  - Syntax node name (when available)

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

The test suite uses a **three-phase architecture**:

**Phase 0: Lean Schema Tests** (`LeanScoutTest.lean`)
- Uses `#guard_msgs` to test schema JSON serialization/deserialization
- Validates roundtrip through Python's schema parser
- Tests all data types: bool, nat, int, float, string, list, struct
- Ensures Lean-generated schemas are correctly parsed by Python
- Run via `lake test`

**Phase 1: Infrastructure Tests** (`test/internals/`)
- Tests Python infrastructure without extracting Lean data
- Focus: Core functionality of writer, orchestrator, CLI, and schema handling
- Uses real subprocess calls (no mocking frameworks)
- Files:
  - `test_schema.py`: Schema querying and deserialization (8 tests)
  - `test_writer.py`: Sharded Parquet writer logic (11 tests)
  - `test_orchestrator.py`: Subprocess management and output parsing (7 tests)
  - `test_cli.py`: CLI utilities like file list reading and library path querying (8 tests)
- Total: 34 tests, fast execution

**Phase 2: Data Extractor Tests** (`test/extractors/`)
- Tests data extractors using `test_project` as a dependency
- Focus: Verifying extractors produce correct output when Scout is used as a dependency
- Files:
  - `test_types.py`: Tests types extractor with `--imports` mode
  - `test_tactics.py`: Tests tactics extractor with `--library` mode and parallel extraction
- Uses YAML specifications (`test/fixtures/types.yaml`, `test/fixtures/tactics.yaml`) for expected outputs
- Extracts data once per test session (module-scoped fixtures)
- Three types of assertions:
  - **Exact matches**: Full field equality for specific constants (e.g., verifying exact tactic strings)
  - **Property checks**: Substring matching and nullability checks (e.g., tactics containing "rw")
  - **Count checks**: Minimum records and required name/tactic existence
- Tests verify schema structure, goal formatting, and parallel extraction correctness

**Test Project** (`test_project/`)
- Minimal Lean project with Scout as a dependency
- Contains simple theorems in `Basic.lean` and `Lists.lean`
- Used to verify extractors work correctly in dependency mode

**Helper Utilities** (`test/helpers.py`)
- Shared extraction functions:
  - `extract_from_dependency_types()`: Runs types extractor with `--imports` mode
  - `extract_from_dependency_library()`: Runs any extractor with `--library` mode and parallel support
- Shared `build_test_project` fixture: Builds test_project once per test session
- Test files contain their own dataset loading and query helpers specific to each extractor

**Integration Script** (`./run_tests`)
- Runs all tests in three phases
- Phase 0: Lean schema tests (`lake test`)
- Phase 1: Infrastructure tests (34 tests)
- Phase 2: Extractor tests
- Provides comprehensive validation of the entire system

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
     go sink
     | .imports tgt => tgt.runCoreM <| Meta.MetaM.run' do
       -- Your extraction logic here
       sink <| json% { id : "...", data : "..." }
     | .input tgt =>
       -- For file-based extraction
       throw <| .userError "Unsupported Target"
   ```
3. Import in `LeanScout/DataExtractors.lean`
4. Rebuild and run: `lake run scout --command mycommand --imports Lean`

Note: The `go` function receives a `sink` function for writing JSON records. Call `sink` with JSON objects to output data.

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
