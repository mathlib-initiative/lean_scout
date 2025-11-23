"""Tests for types data extractor using test_project."""
import pytest
import yaml
import json
import tempfile
import subprocess
from pathlib import Path
from typing import Any, cast
import sys
import glob
from datasets import Dataset

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import (
    TEST_PROJECT_DIR,
    get_record_by_name,
    assert_record_exact_match,
    assert_record_contains,
    assert_record_not_null,
)


def extract_from_dependency_types(library: str, data_dir: Path, working_dir: Path) -> Path:
    subprocess.run(
        ["lake", "run", "scout", "--command", "types", "--dataDir", str(data_dir), "--imports", library],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(working_dir)
    )

    types_dir = data_dir / "types"
    if not types_dir.exists():
        raise RuntimeError(f"Types directory not created: {types_dir}")

    return types_dir


def load_types_dataset(types_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(types_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {types_dir}")

    # Dataset.from_parquet returns Dataset when given a list of file paths
    result = Dataset.from_parquet(cast(Any, parquet_files))
    assert isinstance(result, Dataset)
    return result


@pytest.fixture(scope="module")
def types_dataset_imports():
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)
        types_dir = extract_from_dependency_types(
            "LeanScoutTestProject",
            data_dir,
            TEST_PROJECT_DIR
        )
        dataset = load_types_dataset(types_dir)
        yield dataset


@pytest.fixture(scope="module")
def types_spec():
    spec_path = Path(__file__).parent.parent / "fixtures" / "types.yaml"
    with open(spec_path, 'r') as f:
        return yaml.safe_load(f)


def test_types_imports_exact_matches(types_dataset_imports, types_spec):
    for expected in types_spec['exact_matches']:
        name = expected['name']
        actual = get_record_by_name(types_dataset_imports, name)

        assert actual is not None, f"Record not found: {name}"
        assert_record_exact_match(actual, expected)


def test_types_imports_properties(types_dataset_imports, types_spec):
    for check in types_spec['property_checks']:
        name = check['name']
        actual = get_record_by_name(types_dataset_imports, name)

        assert actual is not None, f"Record not found: {name}"

        props = check['properties']

        if 'module_contains' in props:
            assert_record_contains(actual, 'module', props['module_contains'])

        if 'type_contains' in props:
            assert_record_contains(actual, 'type', props['type_contains'])

        if 'module_not_null' in props and props['module_not_null']:
            assert_record_not_null(actual, 'module')


def test_types_imports_count_min_records(types_dataset_imports, types_spec):
    counts = types_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(types_dataset_imports)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} records, got {actual_count}"
    )


def test_types_imports_has_required_names(types_dataset_imports, types_spec):
    counts = types_spec['count_checks']
    required_names = set(counts['has_names'])
    dataset_names = set(types_dataset_imports['name'])
    missing_names = required_names - dataset_names

    assert len(missing_names) == 0, (
        f"Missing required constants: {sorted(missing_names)}"
    )


def test_types_imports_schema(types_dataset_imports):
    assert len(types_dataset_imports) > 0, "Dataset is empty"

    first_record = types_dataset_imports[0]

    assert 'name' in first_record
    assert 'module' in first_record
    assert 'type' in first_record

    assert isinstance(first_record['name'], str)
    assert first_record['module'] is None or isinstance(first_record['module'], str)
    assert isinstance(first_record['type'], str)


def test_types_imports_modules(types_dataset_imports):
    modules = set(r['module'] for r in types_dataset_imports if r['module'])

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

def extract_types_jsonl(library: str, working_dir: Path) -> list[dict[str, Any]]:
    """Extract types using --jsonl flag and return parsed records."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "types", "--imports", library, "--jsonl"],
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
def types_jsonl_records():
    """Extract types as JSON Lines from test_project."""
    return extract_types_jsonl("LeanScoutTestProject", TEST_PROJECT_DIR)


def test_types_jsonl_output_format(types_jsonl_records):
    """Verify JSON Lines output has valid structure."""
    assert len(types_jsonl_records) > 0, "Should have extracted some records"

    for record in types_jsonl_records:
        assert "name" in record, "Record should have 'name' field"
        assert "type" in record, "Record should have 'type' field"
        assert isinstance(record["name"], str)
        assert isinstance(record["type"], str)


def test_types_jsonl_has_expected_records(types_jsonl_records):
    """Verify expected types are present in JSON Lines output."""
    names = {r["name"] for r in types_jsonl_records}

    expected_names = {"add_zero", "zero_add", "add_comm"}
    missing = expected_names - names
    assert len(missing) == 0, f"Missing expected types: {missing}"


def test_types_jsonl_record_content(types_jsonl_records):
    """Verify specific record content matches expected values."""
    add_zero = next((r for r in types_jsonl_records if r["name"] == "add_zero"), None)
    assert add_zero is not None, "Should find add_zero record"

    assert add_zero["module"] == "LeanScoutTestProject.Basic"
    assert "Nat" in add_zero["type"]


def test_types_jsonl_no_output_directory_created():
    """Verify --jsonl flag does not create output directories."""
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        subprocess.run(
            ["lake", "run", "scout", "--command", "types", "--imports",
             "LeanScoutTestProject", "--jsonl", "--dataDir", str(data_dir)],
            capture_output=True,
            text=True,
            check=True,
            cwd=str(TEST_PROJECT_DIR)
        )

        types_dir = data_dir / "types"
        assert not types_dir.exists(), "--jsonl should not create output directory"


def test_types_jsonl_logs_to_stderr():
    """Verify logs go to stderr, not stdout."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "types", "--imports",
         "LeanScoutTestProject", "--jsonl"],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(TEST_PROJECT_DIR)
    )

    # stdout should only contain valid JSON lines
    for line in result.stdout.strip().split("\n"):
        if line:
            json.loads(line)

    assert "Querying schema" in result.stderr or "Extraction complete" in result.stderr, \
        "Log messages should appear in stderr"

