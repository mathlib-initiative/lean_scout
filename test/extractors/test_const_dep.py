"""Tests for const_dep data extractor using test_project."""
import glob
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, cast

import pytest
import yaml
from datasets import Dataset

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import (
    TEST_PROJECT_DIR,
    assert_record_contains,
    assert_record_not_null,
    get_record_by_name,
)


def extract_from_dependency_const_dep(library: str, data_dir: Path, working_dir: Path) -> Path:
    const_dep_dir = data_dir / "const_dep"
    subprocess.run(
        ["lake", "run", "scout", "--command", "const_dep", "--parquet",
         "--dataDir", str(const_dep_dir), "--imports", library],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(working_dir)
    )

    if not const_dep_dir.exists():
        raise RuntimeError(f"const_dep directory not created: {const_dep_dir}")

    return const_dep_dir


def load_const_dep_dataset(const_dep_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(const_dep_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {const_dep_dir}")

    result = Dataset.from_parquet(cast("Any", parquet_files))
    assert isinstance(result, Dataset)
    return result


@pytest.fixture(scope="module")
def const_dep_dataset_imports():
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)
        const_dep_dir = extract_from_dependency_const_dep(
            "LeanScoutTestProject",
            data_dir,
            TEST_PROJECT_DIR
        )
        dataset = load_const_dep_dataset(const_dep_dir)
        yield dataset


@pytest.fixture(scope="module")
def const_dep_spec():
    spec_path = Path(__file__).parent.parent / "fixtures" / "const_dep.yaml"
    with open(spec_path) as f:
        return yaml.safe_load(f)


def test_const_dep_imports_properties(const_dep_dataset_imports, const_dep_spec):
    for check in const_dep_spec['property_checks']:
        name = check['name']
        actual = get_record_by_name(const_dep_dataset_imports, name)

        assert actual is not None, f"Record not found: {name}"

        props = check['properties']

        if 'module' in props:
            assert actual['module'] == props['module'], (
                f"Module mismatch for {name}: expected {props['module']}, got {actual['module']}"
            )

        if 'module_contains' in props:
            assert_record_contains(actual, 'module', props['module_contains'])

        if props.get('module_not_null'):
            assert_record_not_null(actual, 'module')

        if 'deps_contains' in props:
            dep = props['deps_contains']
            assert dep in actual['deps'], (
                f"Expected '{dep}' in deps for {name}, got: {actual['deps']}"
            )

        if 'deps_contains_all' in props:
            for dep in props['deps_contains_all']:
                assert dep in actual['deps'], (
                    f"Expected '{dep}' in deps for {name}, got: {actual['deps']}"
                )

        if 'transitiveDeps_contains' in props:
            dep = props['transitiveDeps_contains']
            assert dep in actual['transitiveDeps'], (
                f"Expected '{dep}' in transitiveDeps for {name}, got: {actual['transitiveDeps']}"
            )

        if 'transitiveDeps_contains_all' in props:
            for dep in props['transitiveDeps_contains_all']:
                assert dep in actual['transitiveDeps'], (
                    f"Expected '{dep}' in transitiveDeps for {name}, got: {actual['transitiveDeps']}"
                )


def test_const_dep_imports_count_min_records(const_dep_dataset_imports, const_dep_spec):
    counts = const_dep_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(const_dep_dataset_imports)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} records, got {actual_count}"
    )


def test_const_dep_imports_has_required_names(const_dep_dataset_imports, const_dep_spec):
    counts = const_dep_spec['count_checks']
    required_names = set(counts['has_names'])
    dataset_names = set(const_dep_dataset_imports['name'])
    missing_names = required_names - dataset_names

    assert len(missing_names) == 0, (
        f"Missing required constants: {sorted(missing_names)}"
    )


def test_const_dep_imports_schema(const_dep_dataset_imports):
    assert len(const_dep_dataset_imports) > 0, "Dataset is empty"

    first_record = const_dep_dataset_imports[0]

    assert 'name' in first_record
    assert 'module' in first_record
    assert 'deps' in first_record
    assert 'transitiveDeps' in first_record

    assert isinstance(first_record['name'], str)
    assert first_record['module'] is None or isinstance(first_record['module'], str)
    assert isinstance(first_record['deps'], list)
    for dep in first_record['deps']:
        assert isinstance(dep, str)
    assert isinstance(first_record['transitiveDeps'], list)
    for dep in first_record['transitiveDeps']:
        assert isinstance(dep, str)


def test_const_dep_imports_modules(const_dep_dataset_imports):
    modules = {r['module'] for r in const_dep_dataset_imports if r['module']}

    expected_modules = {
        "LeanScoutTestProject.Basic",
        "LeanScoutTestProject.Lists"
    }

    assert expected_modules.issubset(modules), (
        f"Expected modules {expected_modules} to be in dataset modules"
    )


# ============================================================================
# JSON Lines Output Tests
# ============================================================================

def extract_const_dep_jsonl(library: str, working_dir: Path) -> list[dict[str, Any]]:
    """Extract const_dep using --jsonl flag and return parsed records."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "const_dep", "--jsonl", "--imports", library],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(working_dir)
    )

    records = []
    for line in result.stdout.strip().split("\n"):
        if line:
            records.append(json.loads(line))

    return records


@pytest.fixture(scope="module")
def const_dep_jsonl_records():
    """Extract const_dep as JSON Lines from test_project."""
    return extract_const_dep_jsonl("LeanScoutTestProject", TEST_PROJECT_DIR)


def test_const_dep_jsonl_output_format(const_dep_jsonl_records):
    """Verify JSON Lines output has valid structure."""
    assert len(const_dep_jsonl_records) > 0, "Should have extracted some records"

    for record in const_dep_jsonl_records:
        assert "name" in record, "Record should have 'name' field"
        assert "deps" in record, "Record should have 'deps' field"
        assert "transitiveDeps" in record, "Record should have 'transitiveDeps' field"
        assert isinstance(record["name"], str)
        assert isinstance(record["deps"], list)
        assert isinstance(record["transitiveDeps"], list)


def test_const_dep_jsonl_has_expected_records(const_dep_jsonl_records):
    """Verify expected constants are present in JSON Lines output."""
    names = {r["name"] for r in const_dep_jsonl_records}

    expected_names = {"add_zero", "zero_add", "add_comm"}
    missing = expected_names - names
    assert len(missing) == 0, f"Missing expected constants: {missing}"


def test_const_dep_jsonl_record_content(const_dep_jsonl_records):
    """Verify specific record content matches expected values."""
    add_comm = next((r for r in const_dep_jsonl_records if r["name"] == "add_comm"), None)
    assert add_comm is not None, "Should find add_comm record"

    assert add_comm["module"] == "LeanScoutTestProject.Basic"
    # add_comm should have dependencies on Nat lemmas
    assert "Nat.zero_add" in add_comm["deps"]
    assert "Nat.add_zero" in add_comm["deps"]
    # transitiveDeps should contain at least what deps contains, plus more
    assert "Nat.zero_add" in add_comm["transitiveDeps"]
    assert "Nat.add_zero" in add_comm["transitiveDeps"]
    assert "Nat" in add_comm["transitiveDeps"]


def test_const_dep_jsonl_no_output_directory_created():
    """Verify --jsonl flag does not create output directories."""
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        subprocess.run(
            ["lake", "run", "scout", "--command", "const_dep", "--jsonl",
             "--dataDir", str(data_dir), "--imports", "LeanScoutTestProject"],
            capture_output=True,
            text=True,
            check=True,
            cwd=str(TEST_PROJECT_DIR)
        )

        const_dep_dir = data_dir / "const_dep"
        assert not const_dep_dir.exists(), "--jsonl should not create output directory"


def test_const_dep_jsonl_logs_to_stderr():
    """Verify logs go to stderr, not stdout."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "const_dep", "--jsonl",
         "--imports", "LeanScoutTestProject"],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(TEST_PROJECT_DIR)
    )

    # stdout should only contain valid JSON lines
    for line in result.stdout.strip().split("\n"):
        if line:
            json.loads(line)

    assert "[INFO]" in result.stderr or "[ERROR]" in result.stderr, \
        "Log messages should appear in stderr"
