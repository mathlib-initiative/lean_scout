# Lean Scout

Lean Scout is a tool for creating datasets from Lean projects.

## Requirements

To use this tool, you must have:
- A basic Lean4 installation, including `elan`, `lake`, and `lean`. The supported toolchain is tracked in `lean-toolchain`.
- Python 3.13+.
- The `uv` Python package manager.

## Quickstart

Add Lean Scout as a dependency in your project.

### `lakefile.toml`
```toml
[[require]]
name = "lean_scout"
git = "https://github.com/mathlib-initiative/lean_scout.git"
rev = "main" # Prefer pinning to a release tag or commit in production
```

### `lakefile.lean`
```lean
require lean_scout from git
  "https://github.com/mathlib-initiative/lean_scout.git" @ "main"
```

Then, from the root of your Lean4 project, run Lean Scout directly via Lake:
```bash
lake update
lake run scout --command tactics --parquet --library MyLibrary
```

Swap the flags for any invocation (e.g. `--parquet`, `--jsonl`, `--read`, `--imports`, `--dataDir`, shard counts).

> **Note**: The old hosted `extract.sh` wrapper has been removed. Add Lean Scout as a normal Lake dependency and invoke `lake run scout ...` directly.

If you invoke Lean Scout from outside your project root (for example from CI with a different working directory or from another script), pass `--cmdRoot /path/to/project/root` so relative `--read` inputs and output paths stay anchored to that directory.

## GitHub Actions

You can run Lean Scout directly inside CI once your project declares `lean_scout` as a Lake dependency. Here is an example workflow that extracts data from a Lean4 project and uploads it to Hugging Face:
```yml
name: Upload Lean dataset to HuggingFace Hub

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

env:
  HF_DATASET_NAME: my-dataset

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v6
      - uses: leanprover/lean-action@v1

      - name: Install uv
        uses: astral-sh/setup-uv@v4
        with:
          python-version: "3.13"

      - name: Create temp directory
        id: tempdir
        run: echo "path=$(mktemp -d)" >> "$GITHUB_OUTPUT"

      - name: Generate parquet files
        run: |
          lake run scout \
            --command types \
            --parquet \
            --dataDir "${{ steps.tempdir.outputs.path }}" \
            --imports MyLeanModule

      - name: Verify parquet files exist
        run: |
          if ! ls "${{ steps.tempdir.outputs.path }}"/*.parquet 1>/dev/null 2>&1; then
            echo "::error::No parquet files were generated"
            exit 1
          fi
          echo "Generated data:"
          ls -lh "${{ steps.tempdir.outputs.path }}"/*.parquet

      - name: Upload to HuggingFace Hub
        env:
          HF_TOKEN: ${{ secrets.HF_TOKEN }}
        run: |
          uvx hf upload \
            "${{ env.HF_DATASET_NAME }}" \
            "${{ steps.tempdir.outputs.path }}" \
            --repo-type dataset \
            --private \
            --commit-message "Update dataset from ${{ github.sha }}"
```

To use this in your own Lean4 project on GitHub, you must:
- Add Lean Scout as a Lake dependency in your project.
- Set up your Hugging Face write token as a repository secret under `HF_TOKEN`.
- Change `HF_DATASET_NAME: my-dataset` to the dataset you want to update.
- Change the parameters passed to `lake run scout`. The current options extract data about types contained in the environment obtained by importing `MyLeanModule`.
- If your workflow runs from a different working directory, pass `--cmdRoot "$GITHUB_WORKSPACE"` (or another appropriate project root) to keep relative paths anchored correctly.

## Basic usage

Once Lean Scout is available as a dependency, run it from your Lean4 project root.

### Extract from imports
```bash
lake run scout --command types --parquet --imports Lean
```

This will run the `types` command to extract types of constants from an environment created by importing the `Lean` module.

### Extract from files
```bash
# Single file
lake run scout --command tactics --parquet --read MyFile.lean

# Multiple files in parallel (one subprocess per file)
lake run scout --command tactics --parquet --parallel 4 --read File1.lean File2.lean File3.lean

# Extract from entire library (recommended for large codebases)
lake run scout --command tactics --parquet --parallel 8 --library LeanScoutTest
```

For `tactics`, Lean Scout treats syntax, import, elaboration, and type errors in the target file as extraction failures: the run returns a nonzero exit code and no records are emitted for that file.

If you have Lean Scout as a dependency with `Mathlib` as another dependency, you can similarly run:
```bash
lake run scout --command types --parquet --imports Mathlib
```

In both cases, the data will be written to `parquet` files in the `./data/` subdirectory of your Lean4 project.
You can specify the base directory where data is stored as follows:
```bash
lake run scout --command types --parquet --dataDir $HOME/storage/types --imports Mathlib
```

This will write the data to files located within the `$HOME/storage/types/` directory.
The default location is `./data/`.

By default Lean Scout resolves both outputs and relative read targets from the directory where you invoke the command (`--cmdRoot`, default: current working directory). If you run from outside the project root or from automation that changes the working directory, pass `--cmdRoot /path/to/where/paths/are/relative` so relative `--read` paths and outputs stay anchored to that location.

Lean Scout is strict about extraction failures: if any extractor subprocess or the Parquet writer fails, the overall run returns a nonzero exit code, stops launching new targets after the first detected failure, and cancels already-running extractor subprocesses as aggressively as possible.

If an extraction stops early (for example because of `Ctrl+C` or because the run exits with an error), Lean Scout leaves the output directory on disk. If the failed run wrote partial Parquet files, remove the previous output directory or point `--dataDir` to a fresh location before retrying.

### JSON lines

The flag `--jsonl` can be used to extract data directly to stdout.
Parquet files will not be written if using `--jsonl`.

**Note**: logging information is sent to stderr.
In `--parquet` mode, malformed JSON lines reaching the Python writer are treated as fatal errors rather than skipped.

## Extraction Modes

Lean Scout supports multiple extraction modes:

1. **`--imports`**: Extract from an environment created by importing modules (single subprocess)
   - Best for: Extracting types, declarations, or other environment-level data
   - Example: `lake run scout --command types --parquet --imports Lean`

2. **`--read`**: Extract from specific files (parallel subprocesses, one per file)
   - Best for: Processing specific files with per-file data extraction
   - Example: `lake run scout --command tactics --parquet --parallel 4 --read File1.lean File2.lean`

3. **`--library`**: Extract from all modules in a library (parallel subprocesses, recommended)
   - Best for: Processing entire libraries or large codebases
   - Uses `lake query -q <library>:module_paths` to automatically discover all module files
   - Example: `lake run scout --command tactics --parquet --parallel 8 --library LeanScoutTest`

**Note**: The `--library` flag is the recommended approach for extracting data from entire libraries, as it automatically discovers all modules without requiring manual file management.

**Important**: The target flags (`--imports`, `--library`, `--read`) consume all remaining command-line arguments. Place other flags like `--parquet`, `--jsonl`, `--parallel`, `--dataDir` before the target specification.

## Extractor Configuration

Extractors can be configured using the `--config` flag, which accepts a JSON object:

```bash
lake run scout --config '{"taskLimit": 8}' --command types --parquet --imports Lean
```

### Filtering philosophy

Built-in extractors do **not** filter data during extraction.
Instead, they emit enough metadata for users to filter downstream in whatever way matches their use case.

In other words:
- extraction should preserve the raw data
- built-in extractors should expose useful filter metadata
- filtering policy belongs to downstream consumers, not the extraction step

Built-in extractors validate config strictly. Unknown keys and values of the wrong type are treated as extraction errors and cause a nonzero exit code.

**Breaking change**: built-in `filter` config is no longer supported. Filtering should now be done downstream using emitted metadata such as `allowCompletion` and `kind`.

### Available Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `taskLimit` | natural number | unset | Maximum number of concurrent per-constant worker tasks for imports-mode extractors (`types`, `const_dep`) |

**Examples**:
```bash
# Bound imports-mode worker parallelism for imports-mode extractors
lake run scout --config '{"taskLimit": 8}' --command const_dep --parquet --imports Lean

# Tactics accepts an empty config only; filter downstream on `kind`
lake run scout --command tactics --parquet --library MyLib
```

## Sharding

By default, data is organized into 128 parquet shards.
The shard associated with a datapoint is computed by hashing a key, which is specified directly in each data extractor.
The number of shards used can be controlled with the `--numShards` option:
```bash
lake run scout --command types --parquet --numShards 32 --imports Lean
```

## Available Data Extractors

We provide three built-in data extractors: `types`, `tactics`, and `const_dep`.

### `types`
Extracts constant declarations with their types and modules.

**Supported modes**: `--imports` only

**Example**:
```bash
lake run scout --command types --parquet --imports Lean
```

**Output schema**:
- `name` (string): Constant name
- `module` (string, nullable): Module containing the constant
- `type` (string): Type signature
- `allowCompletion` (bool): Whether `Lean.Meta.allowCompletion` holds for the constant

**Configuration**:
- `taskLimit` (optional natural number): Bounds concurrent per-constant worker tasks during imports-mode extraction

**Downstream filtering example**:
```python
filtered = dataset.filter(lambda x: x["allowCompletion"])
```

### `tactics`
Extracts tactic invocations with goal states, used constants, elaborator info, syntax kinds, and source locations.

**Supported modes**: `--read`, `--library`

**Example**:
```bash
lake run scout --command tactics --parquet --parallel 4 --library LeanScoutTest
```

**Output schema**:
- `module` (string, nullable): Module containing the tactic (`null` for plain `--read` files without module setup)
- `startPos` (struct): Start position of the tactic syntax in the source file
  - `line` (nat): 1-based line number
  - `column` (nat): 0-based column number
- `endPos` (struct): End position of the tactic syntax in the source file
  - `line` (nat): 1-based line number
  - `column` (nat): 0-based column number
- `goals` (list): List of goal states before the tactic
  - `pp` (string): Pretty-printed goal
  - `usedConstants` (list of strings): Constants referenced in the goal
- `ppTac` (string): Pretty-printed tactic syntax
- `elaborator` (string): Name of the elaborator that produced this tactic
- `kind` (string): Syntax node kind for the tactic

**Configuration**:
- no built-in extractor-specific options; config must be `{}`

**Downstream filtering example**:
```python
structural = dataset.filter(lambda x: x["kind"] == "Lean.Parser.Tactic.tacticSeq")
```

### `const_dep`
Extracts constant dependency information, mapping each constant to the set of constants it uses.

**Supported modes**: `--imports` only

**Example**:
```bash
lake run scout --command const_dep --parquet --imports Lean
```

**Output schema**:
- `name` (string): Constant name
- `module` (string, nullable): Module containing the constant
- `deps` (list of strings): Names of constants directly used by this constant
- `allowCompletion` (bool): Whether `Lean.Meta.allowCompletion` holds for the parent constant

**Configuration**:
- `taskLimit` (optional natural number): Bounds concurrent per-constant worker tasks during imports-mode extraction

**Downstream filtering example**:
```python
filtered_rows = dataset.filter(lambda x: x["allowCompletion"])
# If you need dependency-level metadata, join dependency names against `types` output.
```

## Creating datasets

It is straightforward to create a dataset (in the sense of `datasets`) from a list of parquet files.
For example, once you run
```bash
lake run scout --command types --parquet --imports Lean
```
to create `parquet` files of the form `./data/*.parquet`, a dataset can be created in python as follows (see `data.ipynb`):
```python
from datasets import Dataset
import glob

dataset = Dataset.from_parquet(glob.glob("./data/*.parquet"))
```
or as follows:
```python
from datasets import load_dataset

dataset = load_dataset("parquet", data_dir="./data", split="train")
```

# How does LeanScout work?

1. The Lean orchestrator (`Main.lean`) manages one or more Lean subprocess(es) that extract data and output JSON lines to stdout
2. For `--parquet` output, the orchestrator spawns a Python process (`cli.py`) that reads JSON from stdin and writes to Parquet files
3. For `--jsonl` output, the orchestrator writes JSON directly to stdout

The orchestration logic is implemented in `Main.lean`, with the Parquet writing handled by `src/lean_scout/cli.py`.

# Testing

### Running Tests

For broad coverage, run both:
```bash
lake test                                        # Lean schema tests (LeanScoutTest.lean)
./run_tests                                      # Main automation suite (ruff, mypy, build, internals, integration, extractors)
```

To run individual components:
```bash
uv run pytest test/internals/ -v                 # Python parquet writer tests
./test/integration/test_lean_orchestrator.sh     # Lean orchestrator integration tests
uv run pytest test/extractors/ -v                # End-to-end extractor tests
```

### Lean Schema Tests

The `lake test` command runs `LeanScoutTest.lean`, which validates:
1. **Schema JSON roundtrip**: All registered data extractors have schemas that serialize to JSON and deserialize back correctly
2. **Schema Python roundtrip**: Schema definitions are correctly parsed by the Python parquet writer (`test/schema.py`)
