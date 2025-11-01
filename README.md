# Lean Scout

Lean Scout is a tool for creating datasets from Lean projects. 

## Requirements

To use this tool, you must have:
- A basic Lean4 installation, including `elan`, `lake`, and `lean`. We currently support `leanprover/lean4:v4.23.0`.
- The `uv` Python package manager.

## Basic usage

To use Lean Scout, add this repo as a dependency in your Lean4 project.
```bash
lake run scout --command types --imports Lean
```

This will run the `types` command to extract types of constants from an environment created by importing the `Lean` module.

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

At a high level, LeanScout works by running a python script `main.py` as a subprocess, and sending the data to this script via stdio.
The python script is responsible for actually writing the data to disk, organized as parquet shards. 

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
- `schema` is the schema of the data being stored. This is serialized into json, and deserialized by the python script responsible for actually storing the data on disk.
- `key` is the key that will be used to compute the shard associated with a given datapoint.
- `go` is the main function that communicates with the python script. The `IO.FS.Handle` parameter is the stdin of the data storing python subprocess, and the `Target` is the target that is being processed.

When declaring a new data extractor, it should be tagged with the `data_extractor` attribute.
The syntax for this is `@[data_extractor cmd]`, where `cmd` is the command that will be used to call the data extractor being defined. 

The syntax `data_extractors`, which is used in the main CLI defined in `Main.lean`, elaborates to a `Std.HashMap Command DataExtractor` which contains all of the data extractors with the associated command that have been tagged as such in the given environment.