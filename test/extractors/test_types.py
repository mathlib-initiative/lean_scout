"""Tests for types data extractor using test_project."""
import pytest
import yaml
import tempfile
import json
from pathlib import Path
import sys
import glob
from datasets import Dataset

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import (
    TEST_PROJECT_DIR,
    build_test_project,
    extract_from_dependency_types,
    get_record_by_name,
    assert_record_exact_match,
    assert_record_contains,
    assert_record_not_null,
)
from lean_scout.cli import get_schema


def load_types_dataset(types_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(types_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {types_dir}")

    return Dataset.from_parquet(parquet_files)  # type: ignore[arg-type]


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


def test_types_schema():
    root_path = Path.cwd()
    schema_json = get_schema("types", root_path)
    schema = json.loads(schema_json)

    assert "fields" in schema
    assert "key" in schema
    assert schema["key"] == "name"

    field_names = [f["name"] for f in schema["fields"]]
    assert "name" in field_names
    assert "module" in field_names
    assert "type" in field_names
