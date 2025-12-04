# Repository Guidelines

## Project Structure & Module Organization
- Lean source lives under `LeanScout/` (core library) and `LeanScoutTest/` (fixtures); entrypoint binary is `Main.lean`.
- Python parquet writer code is in `src/lean_scout/` (`parquet_writer.py`, `cli.py`); packaged via `pyproject.toml`.
- Tests are split by layer: Lean schema checks via `lake test`; Python parquet writer tests in `test/internals/`; Lean orchestrator integration tests in `test/integration/`; end-to-end extractor tests plus fixtures in `test/extractors/` and `test/fixtures/`. Sample Lean project for integration lives in `test_project/`.
- Generated parquet outputs and temporary shards should stay out of version control; configure outputs with `--dataDir` when running commands and use `--cmdRoot` to anchor relative inputs/outputs to the invocation directory when calling from wrappers.

## Build, Test, and Development Commands
Run everything from the repo root (requires `elan`/`lake`, Lean `v4.26.0-rc1`, and `uv`):
```bash
lake build                                       # Build Lean libraries and the lean_scout exe
lake test                                        # Lean schema roundtrip/unit checks
uv run pytest test/internals -v                  # Python parquet writer tests
./test/integration/test_lean_orchestrator.sh    # Lean orchestrator integration tests
uv run pytest test/extractors -v                 # Data extractor tests against fixtures
./run_tests                                      # Full four-phase suite (Lean + Python)
lake run scout --command types --parquet --imports Lean  # Example extractor invocation
```

## Coding Style & Naming Conventions
- Lean: follow standard Lean4 style (two-space indents, modules mirroring paths). Use `UpperCamelCase` for types, `lowerCamelCase` for terms of types, `snake_case` for proofs. 
- Use descriptive tactic names, and keep tactic blocks readable over dense nesting.
- Python: PEP 8 with type hints and docstrings for public functions; `snake_case` for functions/vars, `PascalCase` for classes. Prefer explicit paths (`Path` over strings) and small, testable helpers.
- Keep command-line flags consistent with existing CLI (`--imports`, `--library`, `--read`, `--cmdRoot`); reuse shared utilities rather than re-spawning processes ad hoc.

## Testing Guidelines
- Add or update Lean-facing schemas when introducing new extractors; surface schemas through `Lake` to keep `lake test` passing.
- Place new Python tests near similar coverage (`test/internals/` for pure infra, `test/extractors/` for Lean-backed flows). Name files/functions `test_*.py`.
- Use `uv run pytest` to ensure local environments match CI; prefer concise fixtures and deterministic outputs (no reliance on external network).

## Commit & Pull Request Guidelines
- Write short, imperative commit subjects (<72 chars). Prefix with a scope when helpful (`chore:`, `fix:`, `feat:`) to mirror existing history.
- PRs should describe intent, list key changes, and call out user-visible impacts (new CLI flags, data schema changes). Link issues/tickets when available.
- Include run results for relevant commands (`lake test`, `uv run pytest ...`, or `./run_tests`), plus notes on data output expectations if applicable. Update docs/README when CLI or extractor behavior changes.

# Agent Guidance

## Project Overview
Lean Scout creates datasets from Lean4 projects by extracting structured data (types, tactics) into sharded Parquet outputs.

**Architecture:** Lean orchestrator (`Main.lean`) drives Lean subprocesses that emit JSON; for Parquet output, a Python subprocess (`cli.py`) ingests the JSON and writes to sharded Parquet files; for JSONL output, the Lean orchestrator writes directly to stdout.

## Requirements
- Lean4 via `elan`/`lake`/`lean` (tracked in `lean-toolchain`: `v4.26.0-rc1`)
- `uv` package manager
- Python `>=3.13` (per `pyproject.toml`) with deps: `datasets`, `pyarrow`, `pydantic`, `tqdm`

## Common Commands
- Build: `lake build`
- List extractors: `lake run scout --command extractors`
- Imports target (single subprocess):
  - `lake run scout --command types --parquet --imports Lean`
  - `lake run scout --command types --parquet --dataDir $HOME/storage --imports Mathlib`
  - Sharding: `--numShards 32`
- Read targets (parallel):
  - `lake run scout --command tactics --parquet --read MyFile.lean`
  - `lake run scout --command tactics --parquet --parallel 4 --read File1.lean File2.lean`
  - `lake run scout --command tactics --parquet --parallel 8 --library LeanScoutTest`
  - Target flags (`--imports`, `--library`, `--read`) consume remaining arguments; place other flags before them.

## Testing
- All phases: `./run_tests`
- Lean schemas: `lake test`
- Python parquet writer: `uv run pytest test/internals/ -v`
- Lean orchestrator: `./test/integration/test_lean_orchestrator.sh`
- Extractors: `uv run pytest test/extractors/ -v`

Four-phase suite: Lean schema roundtrips, Python parquet writer, Lean orchestrator CLI integration, extractor outputs against fixtures and the `test_project/` dependency project.

## Architecture Details
- Core Lean type: `DataExtractor` (schema, shard key, extractor function). Registered via `@[data_extractor cmd]` and discovered at compile time.
- Targets: `.imports` (single subprocess) vs `.input` (per-file subprocess; used by `--read`, `--library`).
- Writer: `ShardedParquetWriter` (Python) hashes the key field (BLAKE2b) to shards; used by Lean orchestrator via subprocess.
- Lake config: `scout` lake script adds `--scoutDir` automatically; `module_paths` facet exposes library file lists via `lake query -q <lib>:module_paths`.
- Convenience script: `extract.sh` creates a temporary subproject, builds `lean_scout`, then runs `lake run scout`. Pass `--dataDir` to place outputs somewhere persistent; the default temp directory is ephemeral.
- CLI flags: Target flags (`--imports`, `--library`, `--read`) consume all remaining arguments; place other flags before them.

## Adding Extractors
1) New file in `LeanScout/DataExtractors/`, define `@[data_extractor mycommand]` with schema, key, and extraction logic.
2) Import into `LeanScout/DataExtractors.lean`.
3) Build/run: `lake run scout --command mycommand --parquet --imports Lean`.

## Python Dataset Creation
```python
from datasets import Dataset
import glob
dataset = Dataset.from_parquet(glob.glob("types/*.parquet"))
```
or:
```python
from datasets import load_dataset
dataset = load_dataset("parquet", data_dir="types", split="train")
```
