"""Tests for data extractors when lean_scout is used as a dependency.

This module tests that the data extractors work correctly when lean_scout is
used as a dependency in another project (test_project).
"""
import pytest
import yaml
import tempfile
import subprocess
from pathlib import Path

from helpers import (
    extract_from_dependency_types,
    extract_from_dependency_library,
    load_types_dataset,
    load_tactics_dataset,
    get_record_by_name,
    get_records_by_tactic_contains,
    assert_record_exact_match,
    assert_record_contains,
    assert_record_not_null,
    assert_tactic_contains,
)


# Path to the test project
TEST_PROJECT_DIR = Path(__file__).parent.parent / "test_project"


@pytest.fixture(scope="module", autouse=True)
def build_test_project():
    """
    Build the test project before running any tests.

    This ensures that the test project is compiled and ready for extraction.
    """
    result = subprocess.run(
        ["lake", "build"],
        cwd=str(TEST_PROJECT_DIR),
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Failed to build test project:\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )


@pytest.fixture(scope="module")
def dependency_types_dataset():
    """
    Extract types from LeanScoutTestProject once and reuse for all tests.

    This fixture runs the extraction in a temporary directory from the test_project
    where lean_scout is a dependency.
    """
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
def dependency_tactics_dataset():
    """
    Extract tactics from LeanScoutTestProject once and reuse for all tests.

    This fixture runs the extraction in a temporary directory from the test_project
    where lean_scout is a dependency.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)
        tactics_dir = extract_from_dependency_library(
            "tactics",
            "LeanScoutTestProject",
            data_dir,
            TEST_PROJECT_DIR,
            parallel=2
        )
        dataset = load_tactics_dataset(tactics_dir)
        yield dataset


@pytest.fixture(scope="module")
def dependency_types_spec():
    """Load the dependency_types.yaml test specification."""
    spec_path = Path(__file__).parent / "fixtures" / "dependency_types.yaml"
    with open(spec_path, 'r') as f:
        return yaml.safe_load(f)


@pytest.fixture(scope="module")
def dependency_tactics_spec():
    """Load the dependency_tactics.yaml test specification."""
    spec_path = Path(__file__).parent / "fixtures" / "dependency_tactics.yaml"
    with open(spec_path, 'r') as f:
        return yaml.safe_load(f)


# ============================================================================
# Types Extractor Tests
# ============================================================================

def test_dependency_types_exact_matches(dependency_types_dataset, dependency_types_spec):
    """
    Test exact record matching for types from test project.

    Verifies that theorems defined in LeanScoutTestProject have exactly
    the expected name, module, and type values.
    """
    for expected in dependency_types_spec['exact_matches']:
        name = expected['name']
        actual = get_record_by_name(dependency_types_dataset, name)

        assert actual is not None, f"Record not found: {name}"
        assert_record_exact_match(actual, expected)


def test_dependency_types_properties(dependency_types_dataset, dependency_types_spec):
    """
    Test property-based assertions for types.

    Verifies that specific constants satisfy certain properties.
    """
    for check in dependency_types_spec['property_checks']:
        name = check['name']
        actual = get_record_by_name(dependency_types_dataset, name)

        assert actual is not None, f"Record not found: {name}"

        props = check['properties']

        if 'module_contains' in props:
            assert_record_contains(actual, 'module', props['module_contains'])

        if 'type_contains' in props:
            assert_record_contains(actual, 'type', props['type_contains'])

        if 'module_not_null' in props and props['module_not_null']:
            assert_record_not_null(actual, 'module')


def test_dependency_types_count_min_records(dependency_types_dataset, dependency_types_spec):
    """
    Test minimum record count for types.

    Verifies that the dataset contains at least the expected number of records.
    """
    counts = dependency_types_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(dependency_types_dataset)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} records, got {actual_count}"
    )


def test_dependency_types_has_required_names(dependency_types_dataset, dependency_types_spec):
    """
    Test that all required theorem names exist.

    Verifies that theorems defined in test project are present in the dataset.
    """
    counts = dependency_types_spec['count_checks']
    required_names = set(counts['has_names'])

    # Build set of all names in dataset
    dataset_names = set(dependency_types_dataset['name'])

    # Check for missing names
    missing_names = required_names - dataset_names

    assert len(missing_names) == 0, (
        f"Missing required constants: {sorted(missing_names)}"
    )


def test_dependency_types_schema(dependency_types_dataset):
    """
    Test that the types dataset has the expected schema.

    Verifies that extraction from dependency produces correct schema.
    """
    # Check that dataset is not empty
    assert len(dependency_types_dataset) > 0, "Dataset is empty"

    # Get the first record to inspect schema
    first_record = dependency_types_dataset[0]

    # Verify expected fields exist
    assert 'name' in first_record, "Missing 'name' field"
    assert 'module' in first_record, "Missing 'module' field"
    assert 'type' in first_record, "Missing 'type' field"

    # Verify field types
    assert isinstance(first_record['name'], str), "'name' should be a string"
    assert first_record['module'] is None or isinstance(first_record['module'], str), \
        "'module' should be None or string"
    assert isinstance(first_record['type'], str), "'type' should be a string"


def test_dependency_types_modules(dependency_types_dataset):
    """
    Test that types are extracted from correct modules.

    Verifies that modules are correctly identified for test project theorems.
    """
    # Check that we have records from both modules
    modules = set(r['module'] for r in dependency_types_dataset if r['module'])

    expected_modules = {
        "LeanScoutTestProject.Basic",
        "LeanScoutTestProject.Lists"
    }

    assert expected_modules.issubset(modules), (
        f"Expected modules {expected_modules} to be in dataset modules"
    )


# ============================================================================
# Tactics Extractor Tests
# ============================================================================

def test_dependency_tactics_exact_matches(dependency_tactics_dataset, dependency_tactics_spec):
    """
    Test exact tactic matching for tactics from test project.

    Verifies that specific tactics exist in the dataset.
    """
    for expected in dependency_tactics_spec['exact_matches']:
        ppTac = expected['ppTac']
        from helpers import get_records_by_tactic
        records = get_records_by_tactic(dependency_tactics_dataset, ppTac)

        assert len(records) > 0, f"Tactic not found: {ppTac}"

        # Check if we should verify goals is not empty
        if expected.get('goals_not_empty', False):
            for record in records:
                assert 'goals' in record, f"Missing goals field for tactic: {ppTac}"
                assert isinstance(record['goals'], list), \
                    f"goals should be a list for tactic: {ppTac}"
                assert len(record['goals']) > 0, \
                    f"goals should not be empty for tactic: {ppTac}"


def test_dependency_tactics_contains(dependency_tactics_dataset, dependency_tactics_spec):
    """
    Test that tactics containing specific substrings exist.

    Verifies that tactics from test project appear the expected number of times.
    """
    for check in dependency_tactics_spec['tactic_contains']:
        substring = check['substring']
        min_count = check['min_count']

        assert_tactic_contains(dependency_tactics_dataset, substring, min_count)


def test_dependency_tactics_count_min_records(dependency_tactics_dataset, dependency_tactics_spec):
    """
    Test minimum record count for tactics.

    Verifies that the dataset contains at least the expected number of
    tactic invocations from the test project.
    """
    counts = dependency_tactics_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(dependency_tactics_dataset)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} tactic records, got {actual_count}"
    )


def test_dependency_tactics_has_required_tactics(dependency_tactics_dataset, dependency_tactics_spec):
    """
    Test that all required tactics exist.

    Verifies that tactics used in test project are present in the dataset.
    """
    counts = dependency_tactics_spec['count_checks']
    required_tactics = set(counts['has_tactics'])

    # Build set of all tactics in dataset
    dataset_tactics = set(dependency_tactics_dataset['ppTac'])

    # Check for missing tactics
    missing_tactics = required_tactics - dataset_tactics

    assert len(missing_tactics) == 0, (
        f"Missing required tactics: {sorted(missing_tactics)}"
    )


def test_dependency_tactics_schema(dependency_tactics_dataset):
    """
    Test that the tactics dataset has the expected schema.

    Verifies that extraction from dependency produces correct schema.
    """
    # Check that dataset is not empty
    assert len(dependency_tactics_dataset) > 0, "Dataset is empty"

    # Get the first record to inspect schema
    first_record = dependency_tactics_dataset[0]

    # Verify expected fields exist
    assert 'ppTac' in first_record, "Missing 'ppTac' field"
    assert 'goals' in first_record, "Missing 'goals' field"
    assert 'elaborator' in first_record, "Missing 'elaborator' field"
    assert 'name' in first_record, "Missing 'name' field"

    # Verify field types
    assert isinstance(first_record['ppTac'], str), "'ppTac' should be a string"
    assert isinstance(first_record['goals'], list), "'goals' should be a list"
    assert isinstance(first_record['elaborator'], str), "'elaborator' should be a string"
    assert first_record['name'] is None or isinstance(first_record['name'], str), \
        "'name' should be None or a string"


def test_dependency_tactics_induction(dependency_tactics_dataset):
    """
    Test that induction tactics from add_comm are captured correctly.

    Verifies that the induction tactic used in the test project is extracted
    with proper goal information.
    """
    induction_records = get_records_by_tactic_contains(dependency_tactics_dataset, "induction")

    assert len(induction_records) > 0, "Should have induction tactics from add_comm proof"

    # Verify induction tactics have goals
    for record in induction_records:
        assert len(record['goals']) > 0, "Induction tactics should have goals"


def test_dependency_tactics_rw(dependency_tactics_dataset):
    """
    Test that rewrite tactics are captured correctly.

    Verifies that rw tactics from test project have proper structure.
    """
    rw_records = get_records_by_tactic_contains(dependency_tactics_dataset, "rw")

    assert len(rw_records) > 0, "Should have rewrite tactics from test project"

    # Verify rw tactics have goals
    for record in rw_records:
        assert len(record['goals']) > 0, "Rewrite tactics should have goals"

        # Check that goals have proper structure
        for goal in record['goals']:
            assert 'pp' in goal, "Goal should have 'pp' field"
            assert 'usedConstants' in goal, "Goal should have 'usedConstants' field"
            assert isinstance(goal['pp'], str), "Goal 'pp' should be a string"
            assert isinstance(goal['usedConstants'], list), "Goal 'usedConstants' should be a list"


def test_dependency_tactics_parallel_extraction():
    """
    Test that parallel extraction works correctly from dependency.

    Verifies that using --parallel flag works when lean_scout is a dependency.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Extract with parallel=2
        tactics_dir = extract_from_dependency_library(
            "tactics",
            "LeanScoutTestProject",
            data_dir,
            TEST_PROJECT_DIR,
            parallel=2
        )

        dataset = load_tactics_dataset(tactics_dir)

        # Should have tactics from both Basic.lean and Lists.lean
        assert len(dataset) > 0, "Parallel extraction should produce results"

        # Verify we have tactics from different files by checking for
        # tactics that should only appear in specific files
        rfl_count = len([r for r in dataset if r['ppTac'] == 'rfl'])
        assert rfl_count >= 6, "Should have at least 6 'rfl' tactics from both files"
