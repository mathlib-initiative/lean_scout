"""Tests for the types data extractor."""
import pytest
import yaml
import tempfile
from pathlib import Path

from helpers import (
    extract_types,
    load_types_dataset,
    get_record_by_name,
    assert_record_exact_match,
    assert_record_contains,
    assert_record_not_null,
)


@pytest.fixture(scope="module")
def types_dataset():
    """
    Extract types from Init module once and reuse for all tests.

    This fixture runs the extraction in a temporary directory and loads
    the resulting dataset. It's scoped to the module level so extraction
    only happens once per test session.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)
        types_dir = extract_types("Init", data_dir)
        dataset = load_types_dataset(types_dir)
        yield dataset


@pytest.fixture(scope="module")
def types_spec():
    """Load the types.yaml test specification."""
    spec_path = Path(__file__).parent / "fixtures" / "types.yaml"
    with open(spec_path, 'r') as f:
        return yaml.safe_load(f)


def test_types_exact_matches(types_dataset, types_spec):
    """
    Test exact record matching against specification.

    Verifies that specific constants have exactly the expected name, module,
    and type values as defined in the YAML spec.
    """
    for expected in types_spec['exact_matches']:
        name = expected['name']
        actual = get_record_by_name(types_dataset, name)

        assert actual is not None, f"Record not found: {name}"
        assert_record_exact_match(actual, expected)


def test_types_properties(types_dataset, types_spec):
    """
    Test property-based assertions.

    Verifies that specific constants satisfy certain properties (e.g.,
    module contains a substring, type contains a keyword) without requiring
    exact matches.
    """
    for check in types_spec['property_checks']:
        name = check['name']
        actual = get_record_by_name(types_dataset, name)

        assert actual is not None, f"Record not found: {name}"

        props = check['properties']

        if 'module_contains' in props:
            assert_record_contains(actual, 'module', props['module_contains'])

        if 'type_contains' in props:
            assert_record_contains(actual, 'type', props['type_contains'])

        if 'module_not_null' in props and props['module_not_null']:
            assert_record_not_null(actual, 'module')


def test_types_count_min_records(types_dataset, types_spec):
    """
    Test minimum record count.

    Verifies that the dataset contains at least the expected number of records.
    """
    counts = types_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(types_dataset)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} records, got {actual_count}"
    )


def test_types_has_required_names(types_dataset, types_spec):
    """
    Test that all required constants exist.

    Verifies that specific well-known constants are present in the dataset.
    """
    counts = types_spec['count_checks']
    required_names = set(counts['has_names'])

    # Build set of all names in dataset
    dataset_names = set(types_dataset['name'])

    # Check for missing names
    missing_names = required_names - dataset_names

    assert len(missing_names) == 0, (
        f"Missing required constants: {sorted(missing_names)}"
    )


def test_types_schema(types_dataset):
    """
    Test that the dataset has the expected schema.

    Verifies that the types extractor produces records with the correct fields.
    """
    # Check that dataset is not empty
    assert len(types_dataset) > 0, "Dataset is empty"

    # Get the first record to inspect schema
    first_record = types_dataset[0]

    # Verify expected fields exist
    assert 'name' in first_record, "Missing 'name' field"
    assert 'module' in first_record, "Missing 'module' field"
    assert 'type' in first_record, "Missing 'type' field"

    # Verify field types
    assert isinstance(first_record['name'], str), "'name' should be a string"
    assert first_record['module'] is None or isinstance(first_record['module'], str), \
        "'module' should be None or string"
    assert isinstance(first_record['type'], str), "'type' should be a string"
