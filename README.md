# Lean Scout

Lean Scout is a tool for creating datasets from Lean projects.

## Requirements

To use this tool, you must have:
- A basic Lean4 installation, including `elan`, `lake`, and `lean`. We currently support `leanprover/lean4:v4.26.0-rc2`.
- The `uv` Python package manager.

## Quickstart

From the root of a Lean4 project that includes `lean_scout`, you can stream the wrapper and run it against one of your libraries (here, `MyLibrary`):
```bash
curl -fsSL https://raw.githubusercontent.com/mathlib-initiative/lean_scout/main/extract.py | python3 - --command tactics --library MyLibrary
```
Swap the flags after the script path for any `lean-scout` invocation (e.g., `--read`, `--imports`, `--dataDir`, shard counts). The wrapper reads `lake-manifest.json` and `lean-toolchain` from your current working directory and passes that directory as `--cmdRoot`, so it must be invoked from a Lean4 project root. 
It creates a temporary Lean project with LeanScout and your project as dependencies and runs the LeanScout CLI from there with the appropriate `--cmdRoot`.

## Basic usage

To use Lean Scout, add this repo as a dependency in your Lean4 project.

### Extract from imports
```bash
lake run scout --command types --imports Lean
```

This will run the `types` command to extract types of constants from an environment created by importing the `Lean` module.

### Extract from files
```bash
# Single file
lake run scout --command tactics --read MyFile.lean

# Multiple files in parallel (one subprocess per file)
lake run scout --command tactics --read File1.lean File2.lean File3.lean --parallel 4

# Extract from entire library (recommended for large codebases)
lake run scout --command tactics --library LeanScoutTest --parallel 8

# Or use a file list
echo "File1.lean" > file_list.txt
echo "File2.lean" >> file_list.txt
lake run scout --command tactics --readList file_list.txt --parallel 8
```

If you have Lean Scout as a dependency with `Mathlib` as another dependency, you can similarly run:
```bash
lake run scout --command types --imports Mathlib
```

In both cases, the data will be written to `parquet` files in the `types` subdirectory of your Lean4 project. 
You can specify the base directory where data is stored as follows:
```bash
lake run scout --command types --dataDir $HOME/storage --imports Mathlib
```

This will write the data to files located within the `$HOME/storage/types` directory.

By default Lean Scout resolves both outputs and relative read targets from the directory where you invoke the command (`--cmdRoot`, default: current working directory). If you run via a wrapper script or from outside the Lean project root, pass `--cmdRoot /path/to/where/paths/are/relative` so relative `--read`/`--readList` paths and outputs stay anchored to that location.

If you stop an extraction early (for example with `Ctrl+C`), Lean Scout leaves the partially written Parquet directory on disk; rerunning with the same `--command` and `--dataDir` will fail with a "Data directory … already exists" error. Remove the previous output directory or point `--dataDir` to a fresh location before retrying.
If the extraction exits because of an error, Lean Scout removes the partially written directory for you; manual cleanup is only required when you interrupt the run yourself.

### JSON lines

The flag `--jsonl` can be used to extract data directly to stdout.
Parquet files will not be written if using `--jsonl`.

**Note**: logging information is sent to stderr.

## Extraction Modes

Lean Scout supports multiple extraction modes:

1. **`--imports`**: Extract from an environment created by importing modules (single subprocess)
   - Best for: Extracting types, declarations, or other environment-level data
   - Example: `lake run scout --command types --imports Lean`

2. **`--read`**: Extract from specific files (parallel subprocesses, one per file)
   - Best for: Processing specific files with per-file data extraction
   - Example: `lake run scout --command tactics --read File1.lean File2.lean --parallel 4`

3. **`--library`**: Extract from all modules in a library (parallel subprocesses, recommended)
   - Best for: Processing entire libraries or large codebases
   - Uses `lake query -q <library>:module_paths` to automatically discover all module files
   - Example: `lake run scout --command tactics --library LeanScoutTest --parallel 8`

4. **`--readList`**: Extract from files listed in a text file (parallel subprocesses)
   - Best for: Custom file lists or integration with build systems
   - Example: `lake run scout --command tactics --readList my_files.txt --parallel 8`

**Note**: The `--library` flag is the recommended approach for extracting data from entire libraries, as it automatically discovers all modules without requiring manual file management.

## Sharding

By default, data is organized into 128 parquet shards. 
The shard associated with a datapoint is computed by hashing a key, which is specified directly in each data extractor.
The number of shards used can be controlled with the `--numShards` option:
```bash
lake run scout --command types --numShards 32 --imports Lean
```

## Available Data Extractors

We provide two built-in data extractors: `types` and `tactics`.

### `types`
Extracts constant declarations with their types and modules.

**Supported modes**: `--imports` only

**Example**:
```bash
lake run scout --command types --imports Lean
```

**Output schema**:
- `name` (string): Constant name
- `module` (string, nullable): Module containing the constant
- `type` (string): Type signature

### `tactics`
Extracts tactic invocations with goal states, used constants, elaborator info, and syntax kinds.

**Supported modes**: `--read`, `--readList`, `--library`

**Example**:
```bash
lake run scout --command tactics --library LeanScoutTest --parallel 4
```

**Output schema**:
- `goals` (list): List of goal states before the tactic
  - `pp` (string): Pretty-printed goal
  - `usedConstants` (list of strings): Constants referenced in the goal
- `ppTac` (string): Pretty-printed tactic syntax
- `elaborator` (string): Name of the elaborator that produced this tactic
- `kind` (string): Non-null syntax node kind for the tactic

### List all extractors
```bash
lake run scout --command extractors
```

## Creating datasets

It is straightforward to create a dataset (in the sense of `datasets`) from a list of parquet files.
For example, once you run 
```bash
lake run scout --command types --imports Lean
```
to create `parquet` files of the form `types/*.parquet`, a dataset can be created in python as follows (see `data.ipynb`):
```python
from datasets import Dataset
import glob

dataset = Dataset.from_parquet(glob.glob("types/*.parquet"))
```
or as follows:
```python
from datasets import load_dataset

dataset = load_dataset("parquet", data_dir="types", split="train")
```

# How does LeanScout work?

1. Python orchestrates one or more Lean subprocess(es) that extract data and output JSON lines to stdout
2. The Python orchestrator reads JSON from each subprocess and writes to a shared pool of Parquet writers, or to stdout in the case of `--jsonl`.

The main Python CLI is written in `src/lean_scout/cli.py`.

# Testing

### Running Tests

```bash
# Run all tests (all three phases)
./run_tests

# Run individual phases
lake test                         # Phase 0: Lean schema tests only
uv run pytest test/internals/ -v  # Phase 1: Infrastructure tests only
uv run pytest test/extractors/ -v # Phase 2: Extractor tests only
```
