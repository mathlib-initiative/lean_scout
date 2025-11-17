# Lean Scout Refactoring Plan: Python-First Architecture

## Overview

This plan outlines the refactoring needed to invert the process model from "Lean spawns Python" to "Python spawns Lean". This enables parallel extraction with shared Parquet writers for better performance.

### Current Architecture
```
Lean Executable (Main.lean)
  └─> Spawns: uv run python -m lean_scout
      └─> Python reads JSON from stdin
          └─> ShardedParquetWriter writes Parquet files
```

### New Architecture
```
Python CLI (lean_scout.cli)
  ├─> Spawns: lake exe lean_scout (extractor 1) in parallel
  ├─> Spawns: lake exe lean_scout (extractor 2) in parallel
  └─> Spawns: lake exe lean_scout (extractor 3) in parallel
      └─> All write to shared ShardedParquetWriter pool
```

### Key Benefits
- **Parallel extraction**: Run multiple Lean processes simultaneously
- **Shared writer pool**: Efficient memory usage and file handles
- **Better resource management**: Python orchestrates all subprocess lifecycles
- **Scalability**: Easy to add worker pools and queues later

---

## Files to Modify

### 1. Lean Files

#### ✅ Main.lean (MAJOR CHANGES)
**Location**: `/home/adam/Projects/lean_scout/Main.lean`

**Current behavior**:
- Main entry point that spawns Python subprocess
- Passes schema, shard config, and writes JSON to Python's stdin

**New behavior**:
- Should output JSON lines to stdout instead of subprocess stdin
- Remove subprocess spawning logic entirely
- Accept same command-line arguments for backward compatibility
- Should be simpler and more focused

**Changes needed**:
- [ ] Remove `uv` subprocess spawning code (lines 67-78)
- [ ] Change `extractor.go` to write to stdout instead of subprocess handle
- [ ] Remove basePath, numShards, batchRows arguments (Python will handle)
- [ ] Keep --command, --imports, --read, --scoutPath arguments
- [ ] Simplify main function to just run extractor and output JSON
- [ ] Add output format: one JSON object per line to stdout

**Dependencies**: None

---

#### ✅ LeanScout/Types.lean (MINOR CHANGES)
**Location**: `/home/adam/Projects/lean_scout/LeanScout/Types.lean`

**Current behavior**:
- Defines `DataExtractor` with `go : (Json → IO Unit) → Target → IO Unit`

**New behavior**:
- Signature should remain the same but semantic change
- The sink function will write to stdout instead of subprocess stdin

**Changes needed**:
- [ ] Update docstring to reflect new architecture (lines 49-67)
- [ ] Clarify that `go sink tgt` writes to stdout via `sink`
- [ ] No code changes needed, just documentation

**Dependencies**: None

---

### 2. Python Files

#### ✅ src/lean_scout/__main__.py (COMPLETE REWRITE)
**Location**: `/home/adam/Projects/lean_scout/src/lean_scout/__main__.py`

**Current behavior**:
- CLI entry point that reads JSON from stdin
- Writes to sharded Parquet files
- Standalone subprocess mode

**New behavior**:
- Should be deprecated or converted to a simple shim
- Main CLI logic moves to new `cli.py`
- May keep backward compatibility mode for testing

**Changes needed**:
- [ ] Create new entry point in `cli.py` (see below)
- [ ] Either deprecate this file or make it a legacy mode
- [ ] Update to call new orchestrator when used as main entry point
- [ ] Add deprecation warning if run directly

**Dependencies**: Depends on new `orchestrator.py` and `cli.py`

---

#### ✅ src/lean_scout/cli.py (NEW FILE)
**Location**: `/home/adam/Projects/lean_scout/cli.py`

**Purpose**: New main CLI entry point that orchestrates everything

**Interface**:
```python
def main():
    """Main CLI entry point for lean-scout."""
    parser = argparse.ArgumentParser(description="Extract data from Lean projects")
    parser.add_argument("--command", required=True, help="Extractor command (types, tactics, etc)")
    parser.add_argument("--imports", nargs='+', help="Modules to import")
    parser.add_argument("--read", help="Lean file to read")
    parser.add_argument("--dataDir", default=".", help="Base output directory")
    parser.add_argument("--numShards", type=int, default=128, help="Number of shards")
    parser.add_argument("--batchRows", type=int, default=1024, help="Batch size")
    parser.add_argument("--scoutPath", default=".", help="Scout package root")
    parser.add_argument("--parallel", type=int, default=1, help="Number of parallel extractors")
    args = parser.parse_args()

    # Create orchestrator and run
    orchestrator = Orchestrator(...)
    orchestrator.run()
```

**Changes needed**:
- [ ] Create file with argument parser matching current interface
- [ ] Validate arguments (must have --imports or --read)
- [ ] Query Lean for schema by running: `lake exe lean_scout --command <cmd> --list-schema`
- [ ] Create ShardedParquetWriter with shared state
- [ ] Spawn Lean subprocess(es) via Orchestrator
- [ ] Collect results and close writers
- [ ] Handle errors and cleanup
- [ ] Add progress reporting (optional)

**Dependencies**: Requires `orchestrator.py`, `writer.py`

---

#### ✅ src/lean_scout/orchestrator.py (NEW FILE)
**Location**: `/home/adam/Projects/lean_scout/orchestrator.py`

**Purpose**: Manages parallel Lean subprocess execution and coordinates writing

**Interface**:
```python
class Orchestrator:
    def __init__(self, command: str, target: str, writer: ShardedParquetWriter,
                 scout_path: str, num_workers: int = 1):
        """Initialize orchestrator with shared writer pool."""

    def run(self) -> dict:
        """Run extraction and return statistics."""

    def _spawn_lean_subprocess(self) -> subprocess.Popen:
        """Spawn a single Lean extractor subprocess."""

    def _process_subprocess_output(self, process: subprocess.Popen):
        """Read JSON lines from subprocess stdout and feed to writer."""
```

**Changes needed**:
- [ ] Create Orchestrator class
- [ ] Implement subprocess spawning with proper args
- [ ] Stream stdout line-by-line to avoid buffering issues
- [ ] Parse JSON and feed to ShardedParquetWriter
- [ ] Handle subprocess errors and cleanup
- [ ] Support parallel execution (initially sequential is fine)
- [ ] Add proper logging and error handling
- [ ] Return statistics (rows written, time taken, etc)

**Dependencies**: Requires `writer.py`, `utils.py`

---

#### ✅ src/lean_scout/writer.py (THREAD-SAFETY UPDATES)
**Location**: `/home/adam/Projects/lean_scout/writer.py`

**Current behavior**:
- Manages sharded Parquet writing with batching
- Single-threaded, no concurrency concerns

**New behavior**:
- Should be thread-safe for parallel access
- Multiple orchestrator threads may call `add_record()` concurrently

**Changes needed**:
- [ ] Add `threading.Lock()` to protect shared state
- [ ] Lock around `self.buffers` access in `add_record()`
- [ ] Lock around `self.writers` access in `flush_shard()`
- [ ] Lock around `self.counts` access
- [ ] Test with concurrent access
- [ ] Consider per-shard locks for better concurrency (optional optimization)

**Dependencies**: None (stdlib threading)

---

#### ✅ src/lean_scout/utils.py (NO CHANGES NEEDED)
**Location**: `/home/adam/Projects/lean_scout/utils.py`

**Current behavior**: Schema parsing and JSON streaming utilities

**New behavior**: Same, these utilities are reusable

**Changes needed**:
- [ ] No changes needed
- [ ] May add helper for reading subprocess stdout (optional)

**Dependencies**: None

---

#### ✅ src/lean_scout/__init__.py (MINOR UPDATES)
**Location**: `/home/adam/Projects/lean_scout/__init__.py`

**Current behavior**: Package initialization and exports

**New behavior**: Export new classes and functions

**Changes needed**:
- [ ] Export `Orchestrator` from orchestrator module
- [ ] Update docstring to reflect new architecture
- [ ] Keep backward compatibility exports

**Dependencies**: None

---

### 3. Configuration Files

#### ✅ lakefile.lean (MINOR UPDATES)
**Location**: `/home/adam/Projects/lean_scout/lakefile.lean`

**Current behavior**:
- Defines `scout` script that wraps `lake exe lean_scout` with --scoutPath

**New behavior**:
- Script may need updating depending on new calling convention
- Consider adding a `scout-extractor` script for direct Lean invocation

**Changes needed**:
- [ ] Review if scout script needs changes
- [ ] Consider adding `scout-extractor` for testing extractors directly
- [ ] Update comments if needed

**Dependencies**: Main.lean changes

---

#### ✅ pyproject.toml (MINOR UPDATES)
**Location**: `/home/adam/Projects/lean_scout/pyproject.toml`

**Current behavior**: Defines `lean-scout-writer` script entry point

**New behavior**: Need new entry point for main CLI

**Changes needed**:
- [ ] Change main entry point from `lean-scout-writer` to `lean-scout`
- [ ] Point to new CLI: `"lean-scout = "lean_scout.cli:main"`
- [ ] Keep `lean-scout-writer` for backward compatibility (optional)
- [ ] No new dependencies needed (threading is stdlib)

**Dependencies**: cli.py must exist

---

### 4. Test Files

#### ✅ test/helpers.py (MINOR UPDATES)
**Location**: `/home/adam/Projects/lean_scout/test/helpers.py`

**Current behavior**:
- Helpers call `lake run scout --command types ...`
- This should continue working with new architecture

**New behavior**: Same interface, different underlying implementation

**Changes needed**:
- [ ] No code changes needed (uses lake run scout which will work)
- [ ] Verify tests still pass after refactoring
- [ ] Consider adding helper to test Lean extractor directly (optional)

**Dependencies**: None (calls through lake script)

---

#### ✅ test/test_types.py (NO CHANGES)
**Location**: `/home/adam/Projects/lean_scout/test/test_types.py`

**Changes needed**:
- [ ] No changes needed
- [ ] Verify tests pass after refactoring

**Dependencies**: None

---

#### ✅ test/test_tactics.py (NO CHANGES)
**Location**: `/home/adam/Projects/lean_scout/test/test_tactics.py`

**Changes needed**:
- [ ] No changes needed
- [ ] Verify tests pass after refactoring

**Dependencies**: None

---

#### ✅ run_tests (NO CHANGES)
**Location**: `/home/adam/Projects/lean_scout/run_tests`

**Changes needed**:
- [ ] No changes needed
- [ ] Verify script works after refactoring

**Dependencies**: None

---

### 5. Documentation Files

#### ✅ README.md (MAJOR UPDATES)
**Location**: `/home/adam/Projects/lean_scout/README.md`

**Current behavior**: Documents current architecture

**New behavior**: Document new Python-first architecture

**Changes needed**:
- [ ] Update "How does LeanScout work?" section (lines 63-66)
- [ ] Change description from "Lean runs Python subprocess" to "Python runs Lean subprocess(es)"
- [ ] Add note about parallel extraction capability
- [ ] Update architecture diagram/description
- [ ] Usage examples remain the same (lake run scout)

**Dependencies**: None

---

#### ✅ CLAUDE.md (MAJOR UPDATES)
**Location**: `/home/adam/Projects/lean_scout/CLAUDE.md`

**Current behavior**: Extensive architecture documentation for AI

**New behavior**: Update to reflect new architecture

**Changes needed**:
- [ ] Update "Key Architecture" section (lines 9-12)
- [ ] Update "Data Flow" section (lines 144-151)
- [ ] Update subprocess spawning description (currently says Lean spawns Python)
- [ ] Add section on parallel extraction
- [ ] Update "Python Package Structure" to mention orchestrator
- [ ] Add documentation for new Orchestrator class
- [ ] Update Main.lean description

**Dependencies**: None

---

## Implementation Order

### Phase 1: Core Infrastructure (Do First)
1. **Create src/lean_scout/orchestrator.py** - New orchestrator class (sequential mode only)
2. **Create src/lean_scout/cli.py** - New main CLI entry point
3. **Update src/lean_scout/__init__.py** - Export new modules
4. **Update pyproject.toml** - New entry point

### Phase 2: Modify Lean Code
5. **Modify Main.lean** - Remove subprocess spawning, write to stdout
6. **Update LeanScout/Types.lean** - Update documentation

### Phase 3: Thread Safety
7. **Update src/lean_scout/writer.py** - Add thread safety locks

### Phase 4: Integration & Testing
8. **Test with test/helpers.py** - Verify tests pass
9. **Update run_tests if needed** - Ensure all tests work

### Phase 5: Documentation
10. **Update README.md** - New architecture description
11. **Update CLAUDE.md** - Comprehensive architecture update

### Phase 6: Optimization (Future)
12. **Add parallel extraction to orchestrator.py** - Enable --parallel flag
13. **Optimize writer.py with per-shard locks** - Better concurrency

---

## Technical Decisions & Notes

### Schema Discovery
**Problem**: Python needs to know the schema before spawning Lean.

**Solution Options**:
1. ✅ **Hardcode schema query**: Run `lake exe lean_scout --command types --list-schema` to get schema JSON
2. ❌ Parse schema from first JSON line (breaks parallel extraction)
3. ❌ Duplicate schema definitions in Python (maintenance burden)

**Decision**: Add `--list-schema` flag to Main.lean that outputs schema and exits.

---

### Backward Compatibility
**Problem**: Existing code may depend on `python -m lean_scout` interface.

**Solution**: Keep `__main__.py` working in legacy mode with deprecation warning.

---

### Error Handling
**Problem**: Subprocess failures need proper handling and cleanup.

**Requirements**:
- Capture stderr from Lean processes
- Kill subprocesses on KeyboardInterrupt
- Close all file handles properly
- Report which subprocess failed and why

---

### Progress Reporting
**Problem**: Long-running extractions need progress feedback.

**Solution**:
- Lean can output progress to stderr (doesn't interfere with stdout JSON)
- Python orchestrator can aggregate and display progress
- Use tqdm for progress bars (already a dependency)

---

## Testing Strategy

### Unit Tests
- [ ] Test Orchestrator with mock subprocess
- [ ] Test ShardedParquetWriter thread safety
- [ ] Test CLI argument parsing

### Integration Tests
- [ ] Run full extraction with new architecture
- [ ] Verify Parquet output matches old architecture
- [ ] Test error handling (subprocess crash, invalid JSON, etc.)

### Performance Tests
- [ ] Benchmark sequential vs parallel extraction
- [ ] Verify no performance regression for single-worker mode
- [ ] Measure memory usage with parallel workers

---

## Risks & Mitigations

### Risk 1: Breaking Changes
**Risk**: Existing users may depend on current interface.

**Mitigation**:
- Keep `lake run scout` interface identical
- Add deprecation warnings, not hard breaks
- Test thoroughly before release

### Risk 2: Thread Safety Bugs
**Risk**: Concurrent writes to Parquet may corrupt files.

**Mitigation**:
- Add comprehensive locking in writer.py
- Test with parallel writes
- Consider using process-based parallelism instead of threads (future)

### Risk 3: Subprocess Management Complexity
**Risk**: Managing multiple subprocesses is error-prone.

**Mitigation**:
- Use stdlib subprocess module correctly
- Proper cleanup in finally blocks
- Test error cases explicitly

---

## Future Enhancements

### Parallel Extraction (Phase 6)
- Implement multi-worker subprocess pool in orchestrator
- Load balancing across workers
- Queue-based work distribution for many files

### Process Pool Optimization
- Use `multiprocessing.Pool` for better isolation
- Each worker has own Lean subprocess
- Shared queue for results

### Incremental Extraction
- Skip already-processed files
- Resume interrupted extractions
- Checkpointing support

### Distributed Extraction
- Extract across multiple machines
- Centralized result collection
- Distributed file system support

---

## Checklist Summary

### Lean Files (2 files)
- [ ] Main.lean - Complete rewrite of main function
- [ ] LeanScout/Types.lean - Documentation updates

### Python Files (5 files)
- [ ] src/lean_scout/cli.py - NEW: Main CLI entry point
- [ ] src/lean_scout/orchestrator.py - NEW: Subprocess orchestration
- [ ] src/lean_scout/__main__.py - Deprecate or convert to shim
- [ ] src/lean_scout/writer.py - Add thread safety
- [ ] src/lean_scout/__init__.py - Export new modules

### Configuration (2 files)
- [ ] pyproject.toml - Update entry points
- [ ] lakefile.lean - Review and update if needed

### Documentation (2 files)
- [ ] README.md - Architecture updates
- [ ] CLAUDE.md - Comprehensive architecture documentation

### Tests (4 files)
- [ ] test/helpers.py - Verify compatibility (may need minor updates)
- [ ] test/test_types.py - Verify tests pass
- [ ] test/test_tactics.py - Verify tests pass
- [ ] run_tests - Verify script works

### Total: 15 files to modify/create

---

## Questions to Resolve

1. **Schema Discovery**: Should we add `--list-schema` flag or hardcode schemas in Python?
   - Recommendation: Add `--list-schema` flag for maintainability

2. **Backward Compatibility**: Should we maintain `python -m lean_scout` interface?
   - Recommendation: Yes, with deprecation warning

3. **Parallel Strategy**: Start with sequential or implement parallel immediately?
   - Recommendation: Start sequential, add parallel in Phase 6

4. **Entry Point Name**: `lean-scout` or `lean_scout` or something else?
   - Recommendation: `lean-scout` (with hyphen, Python convention for CLI tools)

---

## Success Criteria

- [ ] All existing tests pass
- [ ] `lake run scout --command types --imports Init` works identically
- [ ] Parquet output format is unchanged
- [ ] No performance regression in sequential mode
- [ ] Code is well-documented and maintainable
- [ ] Architecture supports future parallel extraction
