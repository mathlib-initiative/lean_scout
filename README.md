# Lean Scout

Lean Scout is a tool for creating datasets from Lean projects. 

## Requirements

To use this tool, you must have:
- A basic Lean4 installation, including `elan`, `lake`, and `lean`. We currently support `leanprover/lean4:v4.23.0`.
- The `uv` Python package manager.

## Basic usage

To use Lean Scout, add this repo as a dependency in your Lean4 project.

### Extract from imports (single subprocess)
```bash
lake run scout --command types --imports Lean
```

This will run the `types` command to extract types of constants from an environment created by importing the `Lean` module.

### Extract from files (parallel subprocesses)
```bash
# Single file
lake run scout --command tactics --read MyFile.lean

# Multiple files in parallel (one subprocess per file)
lake run scout --command tactics --read File1.lean File2.lean File3.lean --parallel 4

# Read file list from a file (useful for many files)
lake build LeanScout:module_paths  # Creates file with all module paths
lake run scout --command tactics --read-list module_paths --parallel 8
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

## Sharding

By default, data is organized into 128 parquet shards. 
The shard associated with a datapoint is computed by hashing a key, which is specified directly in each data extractor.
The number of shards used can be controlled with the `--numShards` option:
```bash
lake run scout --command types --numShards 32 --imports Lean
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

At a high level, LeanScout uses a **Python-first architecture**:
1. Python orchestrates one or more Lean subprocess(es) that extract data and output JSON lines to stdout
2. The Python orchestrator reads JSON from each subprocess and writes to a shared pool of Parquet writers
3. This design enables **parallel extraction** where multiple Lean processes can run simultaneously while sharing efficient Parquet writers

The data is written to disk organized as sharded Parquet files for efficient storage and loading. 

# Data Extractors

LeanScout uses "data extractors" to create datasets.
The type of data extractors is defined as follows:
```lean
structure DataExtractor where
  schema : Arrow.Schema
  key : String
  go : IO.FS.Handle → Target → IO Unit 
```

Here,
- `schema` is the schema of the data being stored. This is serialized to JSON and queried by the Python orchestrator before extraction begins.
- `key` is the field name that will be used to compute the shard associated with a given datapoint (via hashing).
- `go` is the main function that extracts data and writes JSON lines to stdout. The `IO.FS.Handle` parameter writes to stdout, and the `Target` is the target that is being processed (either imports or a file to read).

When declaring a new data extractor, it should be tagged with the `data_extractor` attribute.
The syntax for this is `@[data_extractor cmd]`, where `cmd` is the command that will be used to call the data extractor being defined. 

The syntax `data_extractors`, which is used in the main CLI defined in `Main.lean`, elaborates to a `Std.HashMap Command DataExtractor` which contains all of the data extractors with the associated command that have been tagged as such in the given environment.