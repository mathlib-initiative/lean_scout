# Extraction consistency regression plan

## Goal

Add an automated regression test that verifies Lean Scout produces the same **complete dataset** across:

- both supported writers: `--jsonl` and `--parquet`
- different parallelism settings
- every supported extractor/target combination

The comparison should be **semantic**, not byte-for-byte:

- record order should be ignored
- fields that are semantically sets should be normalized before comparison
- the result should be compared as a multiset of normalized records

## Supported combinations to cover

These are the combinations currently supported by Lean Scout and should be included in the future regression harness:

1. `types --imports ...`
2. `const_dep --imports ...`
3. `tactics --read ...`
4. `tactics --library ...`

## Recommended target matrix

Use two classes of targets:

### 1. Small project target
Run from `test_project/` and use:

- imports target: `LeanScoutTestProject`
- read target:
  - `LeanScoutTestProject.lean`
  - `LeanScoutTestProject/Basic.lean`
  - `LeanScoutTestProject/Lists.lean`
- library target: `LeanScoutTestProject`

This gives a fast, deterministic project-local target that exercises all public extraction modes.

### 2. Standard library target
Also run from `test_project/` and use:

- imports target: `Init`

This is large enough to exercise imports-mode extraction under more realistic load.

## Parallelism matrix

### Imports-mode extractors (`types`, `const_dep`)

These do not use top-level `--parallel` in a meaningful way because `--imports` launches a single extractor subprocess.
Their effective parallelism is controlled by extractor config field `taskLimit`.

Recommended settings:

- default config: `{}`
- `{"taskLimit": 1}`
- `{"taskLimit": 4}`

### Input-mode extractor (`tactics`)

For `--read` and `--library`, vary top-level `--parallel`:

- `--parallel 1`
- `--parallel 2`
- `--parallel 4`

## Writer matrix

For each scenario, run both:

- `--jsonl`
- `--parquet`

## What to compare

For each fixed extractor/target scenario, compare all writer/parallel variants against a baseline run.

### Normalization rules

Normalize records before comparison:

- compare records as a **multiset** of canonical JSON values
- sort object keys when canonicalizing
- ignore overall output order
- for `const_dep`, sort the `deps` array before canonicalization
- for `tactics`, sort each goal's `usedConstants` array before canonicalization
- for `tactics`, keep the `goals` array order unchanged

These rules reflect current schema semantics:

- `deps` is conceptually a set
- `usedConstants` is conceptually a set
- record order should not matter across writers or parallel schedules
- goal order *does* matter

## Additional cross-target check

For the `tactics` extractor, also compare:

- `--read LeanScoutTestProject.lean LeanScoutTestProject/Basic.lean LeanScoutTestProject/Lists.lean`
- `--library LeanScoutTestProject`

These should produce the same normalized dataset, because the library target resolves to the same module-path set.

## Suggested harness structure

Implement this later as a Python integration harness, for example in one of:

- `test/integration/`
- `test/extractors/`

Suggested pieces:

1. **Runner**
   - launches `lake run scout ...`
   - captures JSONL stdout to a file
   - writes Parquet output to a temporary directory
   - stores stderr logs for debugging

2. **Loaders**
   - JSONL loader from stdout file
   - Parquet loader via `pyarrow.dataset`

3. **Normalizer**
   - canonicalizes each record into a stable JSON string
   - applies extractor-specific list normalization rules

4. **Comparator**
   - compares `Counter[canonical_record]` values
   - on mismatch, reports:
     - missing sample records
     - extra sample records
     - record counts
     - the exact command that produced the mismatch

5. **Report output**
   - print per-case record counts and signatures
   - keep temp artifacts on failure for manual inspection

## Recommended commands

Run from `test_project/`.

### Types / imports

```bash
lake run scout --command types --jsonl --imports LeanScoutTestProject
lake run scout --command types --parquet --dataDir <dir> --imports LeanScoutTestProject
lake run scout --command types --jsonl --config '{"taskLimit":1}' --imports LeanScoutTestProject
lake run scout --command types --jsonl --config '{"taskLimit":4}' --imports LeanScoutTestProject
lake run scout --command types --jsonl --imports Init
lake run scout --command types --jsonl --config '{"taskLimit":1}' --imports Init
lake run scout --command types --jsonl --config '{"taskLimit":4}' --imports Init
```

Repeat the same matrix with `--parquet`.

### Const dep / imports

```bash
lake run scout --command const_dep --jsonl --imports LeanScoutTestProject
lake run scout --command const_dep --parquet --dataDir <dir> --imports LeanScoutTestProject
lake run scout --command const_dep --jsonl --config '{"taskLimit":1}' --imports LeanScoutTestProject
lake run scout --command const_dep --jsonl --config '{"taskLimit":4}' --imports LeanScoutTestProject
lake run scout --command const_dep --jsonl --imports Init
lake run scout --command const_dep --jsonl --config '{"taskLimit":1}' --imports Init
lake run scout --command const_dep --jsonl --config '{"taskLimit":4}' --imports Init
```

Repeat the same matrix with `--parquet`.

### Tactics / read

```bash
lake run scout --command tactics --jsonl --parallel 1 \
  --read LeanScoutTestProject.lean LeanScoutTestProject/Basic.lean LeanScoutTestProject/Lists.lean

lake run scout --command tactics --jsonl --parallel 2 \
  --read LeanScoutTestProject.lean LeanScoutTestProject/Basic.lean LeanScoutTestProject/Lists.lean

lake run scout --command tactics --jsonl --parallel 4 \
  --read LeanScoutTestProject.lean LeanScoutTestProject/Basic.lean LeanScoutTestProject/Lists.lean
```

Repeat the same matrix with `--parquet`.

### Tactics / library

```bash
lake run scout --command tactics --jsonl --parallel 1 --library LeanScoutTestProject
lake run scout --command tactics --jsonl --parallel 2 --library LeanScoutTestProject
lake run scout --command tactics --jsonl --parallel 4 --library LeanScoutTestProject
```

Repeat the same matrix with `--parquet`.

## Expected runtime

A full manual run of the matrix above took about **13 minutes** on the current development machine.

The slowest cases were the imports-mode runs with `taskLimit = 1`, so this is a good candidate for:

- a nightly job, or
- a pre-merge workflow that is run selectively rather than on every push

## Current manual status

This plan is based on a manual consistency check run over a 36-case matrix:

- 24 imports-mode runs (`types` / `const_dep`, two targets, three `taskLimit` settings, two writers)
- 12 tactics runs (`--read` / `--library`, three `--parallel` settings, two writers)

That manual run found:

- identical normalized datasets across all writer/parallel variants within each scenario
- matching `tactics --read` and `tactics --library` outputs for the `LeanScoutTestProject` target set

So the current branch passed the intended consistency check manually.
