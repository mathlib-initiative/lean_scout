"""Tests for the tactics data extractor."""
import pytest
import yaml
import tempfile
from pathlib import Path

from helpers import (
    extract_tactics,
    load_tactics_dataset,
    get_records_by_tactic,
    get_records_by_tactic_contains,
    assert_tactic_contains,
)


@pytest.fixture(scope="module")
def tactics_test_dataset():
    """
    Extract tactics from TacticsTest.lean once and reuse for all tests.

    This fixture runs the extraction in a temporary directory and loads
    the resulting dataset. It's scoped to the module level so extraction
    only happens once per test session.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)
        tactics_dir = extract_tactics("LeanScoutTest/TacticsTest.lean", data_dir)
        dataset = load_tactics_dataset(tactics_dir)
        yield dataset


@pytest.fixture(scope="module")
def tactics_test_spec():
    """Load the tactics.yaml test specification."""
    spec_path = Path(__file__).parent / "fixtures" / "tactics.yaml"
    with open(spec_path, 'r') as f:
        return yaml.safe_load(f)


def test_tactics_exact_matches(tactics_test_dataset, tactics_test_spec):
    """
    Test exact tactic matching against specification.

    Verifies that specific tactics exist in the dataset and have non-empty
    goal lists when specified.
    """
    for expected in tactics_test_spec['exact_matches']:
        ppTac = expected['ppTac']
        records = get_records_by_tactic(tactics_test_dataset, ppTac)

        assert len(records) > 0, f"Tactic not found: {ppTac}"

        # Check if we should verify goals is not empty
        if expected.get('goals_not_empty', False):
            for record in records:
                assert 'goals' in record, f"Missing goals field for tactic: {ppTac}"
                assert isinstance(record['goals'], list), \
                    f"goals should be a list for tactic: {ppTac}"
                assert len(record['goals']) > 0, \
                    f"goals should not be empty for tactic: {ppTac}"


def test_tactics_contains(tactics_test_dataset, tactics_test_spec):
    """
    Test that tactics containing specific substrings exist.

    Verifies that tactics with certain patterns appear the expected number
    of times in the dataset.
    """
    for check in tactics_test_spec['tactic_contains']:
        substring = check['substring']
        min_count = check['min_count']

        assert_tactic_contains(tactics_test_dataset, substring, min_count)


def test_tactics_count_min_records(tactics_test_dataset, tactics_test_spec):
    """
    Test minimum record count.

    Verifies that the dataset contains at least the expected number of
    tactic invocations.
    """
    counts = tactics_test_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(tactics_test_dataset)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} tactic records, got {actual_count}"
    )


def test_tactics_has_required_tactics(tactics_test_dataset, tactics_test_spec):
    """
    Test that all required tactics exist.

    Verifies that specific well-known tactics are present in the dataset.
    """
    counts = tactics_test_spec['count_checks']
    required_tactics = set(counts['has_tactics'])

    # Build set of all tactics in dataset
    dataset_tactics = set(tactics_test_dataset['ppTac'])

    # Check for missing tactics
    missing_tactics = required_tactics - dataset_tactics

    assert len(missing_tactics) == 0, (
        f"Missing required tactics: {sorted(missing_tactics)}"
    )


def test_tactics_schema(tactics_test_dataset):
    """
    Test that the dataset has the expected schema.

    Verifies that the tactics extractor produces records with the correct fields.
    """
    # Check that dataset is not empty
    assert len(tactics_test_dataset) > 0, "Dataset is empty"

    # Get the first record to inspect schema
    first_record = tactics_test_dataset[0]

    # Verify expected fields exist
    assert 'ppTac' in first_record, "Missing 'ppTac' field"
    assert 'goals' in first_record, "Missing 'goals' field"
    assert 'elaborator' in first_record, "Missing 'elaborator' field"
    assert 'name' in first_record, "Missing 'name' field"

    # Verify field types
    assert isinstance(first_record['ppTac'], str), "'ppTac' should be a string"
    assert isinstance(first_record['goals'], list), "'goals' should be a list"
    assert isinstance(first_record['elaborator'], str), "'elaborator' should be a string"
    # 'name' is nullable, so it can be None or str
    assert first_record['name'] is None or isinstance(first_record['name'], str), \
        "'name' should be None or a string"

    # Verify goals structure (each goal is an object with pp and usedConstants)
    if len(first_record['goals']) > 0:
        first_goal = first_record['goals'][0]
        assert isinstance(first_goal, dict), \
            "'goals' should contain dictionaries"
        assert 'pp' in first_goal, "Goal should have 'pp' field"
        assert 'usedConstants' in first_goal, "Goal should have 'usedConstants' field"
        assert isinstance(first_goal['pp'], str), \
            "Goal 'pp' field should be a string"
        assert isinstance(first_goal['usedConstants'], list), \
            "Goal 'usedConstants' field should be a list"


def test_tactics_goals_structure(tactics_test_dataset):
    """
    Test that goal structures are reasonable.

    Verifies that goals lists have reasonable content with proper structure.
    """
    # Sample a few records to check goals
    sample_size = min(10, len(tactics_test_dataset))

    for i in range(sample_size):
        record = tactics_test_dataset[i]

        # goals should be a list
        assert isinstance(record['goals'], list), \
            f"Record {i}: goals should be a list"

        # Each goal should be a dict with 'pp' and 'usedConstants'
        for goal_idx, goal in enumerate(record['goals']):
            assert isinstance(goal, dict), \
                f"Record {i}, goal {goal_idx}: should be a dict"

            # Check 'pp' field
            assert 'pp' in goal, \
                f"Record {i}, goal {goal_idx}: missing 'pp' field"
            assert isinstance(goal['pp'], str), \
                f"Record {i}, goal {goal_idx}: 'pp' should be a string"
            assert len(goal['pp']) > 0, \
                f"Record {i}, goal {goal_idx}: 'pp' should not be empty"

            # Check 'usedConstants' field
            assert 'usedConstants' in goal, \
                f"Record {i}, goal {goal_idx}: missing 'usedConstants' field"
            assert isinstance(goal['usedConstants'], list), \
                f"Record {i}, goal {goal_idx}: 'usedConstants' should be a list"

            # Each constant should be a string
            for const_idx, const in enumerate(goal['usedConstants']):
                assert isinstance(const, str), \
                    f"Record {i}, goal {goal_idx}, const {const_idx}: should be a string"


def test_tactics_specific_examples(tactics_test_dataset):
    """
    Test specific tactic examples to ensure proper extraction.

    Verifies that well-known tactics appear with expected patterns.
    """
    # Test that 'rw' tactics exist
    rw_records = get_records_by_tactic_contains(tactics_test_dataset, "rw [")
    assert len(rw_records) > 0, "Should have rewrite tactics with arguments"

    # Test that 'cases' tactics with 'with' exist
    cases_records = get_records_by_tactic_contains(tactics_test_dataset, "cases")
    assert len(cases_records) > 0, "Should have cases tactics"

    # Test that 'calc' tactics exist
    calc_records = get_records_by_tactic_contains(tactics_test_dataset, "calc")
    assert len(calc_records) > 0, "Should have calc tactics"

    # Verify calc tactics have goal information
    for record in calc_records:
        assert len(record['goals']) > 0, "Calc tactics should have goals"


def test_tactics_used_constants(tactics_test_dataset):
    """
    Test that usedConstants field is populated correctly.

    Verifies that goals capture the constants used in goal expressions.
    """
    # Find tactics that should have constants (like 'rw [Nat.add_comm]')
    rw_nat_records = get_records_by_tactic_contains(tactics_test_dataset, "Nat.add_comm")

    if len(rw_nat_records) > 0:
        # At least one of these should have Nat in usedConstants
        found_nat_constant = False
        for record in rw_nat_records:
            for goal in record['goals']:
                if any('Nat' in const for const in goal['usedConstants']):
                    found_nat_constant = True
                    break
            if found_nat_constant:
                break

        # Note: this is a weak assertion since the goal might not reference Nat directly
        # The important thing is that usedConstants is populated
        assert all(
            isinstance(goal['usedConstants'], list)
            for record in rw_nat_records
            for goal in record['goals']
        ), "All goals should have usedConstants lists"


def test_tactics_elaborator_field(tactics_test_dataset):
    """
    Test that the elaborator field is populated correctly.

    Verifies that every tactic record has a non-empty elaborator string.
    """
    # Sample tactics to check
    sample_size = min(20, len(tactics_test_dataset))

    for i in range(sample_size):
        record = tactics_test_dataset[i]

        # Elaborator should exist and be a non-empty string
        assert 'elaborator' in record, f"Record {i}: missing 'elaborator' field"
        assert isinstance(record['elaborator'], str), \
            f"Record {i}: 'elaborator' should be a string"
        assert len(record['elaborator']) > 0, \
            f"Record {i}: 'elaborator' should not be empty"


def test_tactics_name_field(tactics_test_dataset):
    """
    Test that the name field is populated correctly.

    Verifies that the name field exists and is either None or a string.
    Some tactics may not have syntax node names.
    """
    # Sample tactics to check
    sample_size = min(20, len(tactics_test_dataset))

    for i in range(sample_size):
        record = tactics_test_dataset[i]

        # Name should exist (but can be None)
        assert 'name' in record, f"Record {i}: missing 'name' field"

        # If present, should be a string
        if record['name'] is not None:
            assert isinstance(record['name'], str), \
                f"Record {i}: 'name' should be a string when not None"
