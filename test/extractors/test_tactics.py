"""Tests for tactics data extractor using test_project."""
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
    extract_from_dependency_library,
)


def load_tactics_dataset(tactics_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {tactics_dir}")

    # Dataset.from_parquet returns Dataset when given a list of file paths
    result = Dataset.from_parquet(cast("Any", parquet_files))
    assert isinstance(result, Dataset)
    return result


def get_records_by_tactic(dataset: Dataset, tactic: str):
    matches = dataset.filter(lambda x: x['ppTac'] == tactic)
    return [matches[i] for i in range(len(matches))]


def get_records_by_tactic_contains(dataset: Dataset, substring: str):
    matches = dataset.filter(lambda x: substring in x['ppTac'])
    return [matches[i] for i in range(len(matches))]


def assert_tactic_contains(dataset: Dataset, substring: str, min_count: int = 1):
    matches = get_records_by_tactic_contains(dataset, substring)
    assert len(matches) >= min_count, (
        f"Expected at least {min_count} tactics containing '{substring}', "
        f"found {len(matches)}"
    )


@pytest.fixture(scope="module")
def tactics_dataset():
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
def tactics_spec():
    spec_path = Path(__file__).parent.parent / "fixtures" / "tactics.yaml"
    with open(spec_path) as f:
        return yaml.safe_load(f)


def test_tactics_exact_matches(tactics_dataset, tactics_spec):
    for expected in tactics_spec['exact_matches']:
        pp_tac = expected['ppTac']
        records = get_records_by_tactic(tactics_dataset, pp_tac)

        assert len(records) > 0, f"Tactic not found: {pp_tac}"

        if expected.get('goals_not_empty', False):
            for record in records:
                assert 'goals' in record, f"Missing goals field for tactic: {pp_tac}"
                assert isinstance(record['goals'], list), \
                    f"goals should be a list for tactic: {pp_tac}"
                assert len(record['goals']) > 0, \
                    f"goals should not be empty for tactic: {pp_tac}"


def test_tactics_contains(tactics_dataset, tactics_spec):
    for check in tactics_spec['tactic_contains']:
        substring = check['substring']
        min_count = check['min_count']

        assert_tactic_contains(tactics_dataset, substring, min_count)


def test_tactics_count_min_records(tactics_dataset, tactics_spec):
    counts = tactics_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(tactics_dataset)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} tactic records, got {actual_count}"
    )


def test_tactics_has_required_tactics(tactics_dataset, tactics_spec):
    counts = tactics_spec['count_checks']
    required_tactics = set(counts['has_tactics'])
    dataset_tactics = set(tactics_dataset['ppTac'])
    missing_tactics = required_tactics - dataset_tactics

    assert len(missing_tactics) == 0, (
        f"Missing required tactics: {sorted(missing_tactics)}"
    )


def test_tactics_dataset_record_schema(tactics_dataset):
    assert len(tactics_dataset) > 0, "Dataset is empty"

    first_record = tactics_dataset[0]

    assert 'ppTac' in first_record
    assert 'goals' in first_record
    assert 'elaborator' in first_record
    assert 'kind' in first_record

    assert isinstance(first_record['ppTac'], str)
    assert isinstance(first_record['goals'], list)
    assert isinstance(first_record['elaborator'], str)
    assert isinstance(first_record['kind'], str)


def test_tactics_induction(tactics_dataset):
    induction_records = get_records_by_tactic_contains(tactics_dataset, "induction")

    assert len(induction_records) > 0, "Should have induction tactics from add_comm proof"

    for record in induction_records:
        assert len(record['goals']) > 0, "Induction tactics should have goals"


def test_tactics_rw(tactics_dataset):
    rw_records = get_records_by_tactic_contains(tactics_dataset, "rw")

    assert len(rw_records) > 0, "Should have rewrite tactics from test project"

    records_with_goals = [r for r in rw_records if len(r['goals']) > 0]
    assert len(records_with_goals) > 0, "At least some rewrite tactics should have goals"

    for record in records_with_goals:
        for goal in record['goals']:
            assert 'pp' in goal
            assert 'usedConstants' in goal
            assert isinstance(goal['pp'], str)
            assert isinstance(goal['usedConstants'], list)


def test_tactics_parallel_extraction():
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

        assert len(dataset) > 0, "Parallel extraction should produce results"

        records: list[dict[str, Any]] = [dict(r) for r in dataset]
        rfl_count = len([r for r in records if r['ppTac'] == 'rfl'])
        assert rfl_count >= 6, "Should have at least 6 'rfl' tactics from both files"


def test_tactics_goal_structure(tactics_dataset):
    for record in tactics_dataset:
        if len(record['goals']) > 0:
            for goal in record['goals']:
                assert 'pp' in goal, f"Goal missing 'pp' for tactic {record['ppTac']}"
                assert 'usedConstants' in goal, f"Goal missing 'usedConstants' for tactic {record['ppTac']}"

                assert isinstance(goal['pp'], str), f"Goal 'pp' should be string for tactic {record['ppTac']}"
                assert isinstance(goal['usedConstants'], list), f"Goal 'usedConstants' should be list for tactic {record['ppTac']}"


def test_tactics_elaborator_field(tactics_dataset):
    for record in tactics_dataset:
        assert 'elaborator' in record, f"Missing elaborator for tactic {record['ppTac']}"
        assert isinstance(record['elaborator'], str), f"Elaborator should be string for tactic {record['ppTac']}"
        assert len(record['elaborator']) > 0, f"Elaborator should not be empty for tactic {record['ppTac']}"


def test_tactics_rfl_from_test_project(tactics_dataset):
    rfl_records = get_records_by_tactic(tactics_dataset, "rfl")

    assert len(rfl_records) >= 3, "Should have multiple rfl tactics from test project"

    for record in rfl_records:
        assert len(record['goals']) > 0, "rfl should have at least one goal"


# ============================================================================
# JSON Lines Output Tests
# ============================================================================

def extract_tactics_jsonl(library: str, working_dir: Path) -> list[dict[str, Any]]:
    """Extract tactics using --jsonl flag and return parsed records."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "tactics", "--library", library,
         "--parallel", "1", "--jsonl"],
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
def tactics_jsonl_records():
    """Extract tactics as JSON Lines from test_project."""
    return extract_tactics_jsonl("LeanScoutTestProject", TEST_PROJECT_DIR)


def test_tactics_jsonl_output_format(tactics_jsonl_records):
    """Verify tactics JSON Lines output has valid structure."""
    assert len(tactics_jsonl_records) > 0, "Should have extracted some tactic records"

    for record in tactics_jsonl_records:
        assert "ppTac" in record, "Tactic record should have 'ppTac' field"
        assert "goals" in record, "Tactic record should have 'goals' field"
        assert "kind" in record, "Tactic record should have 'kind' field"


def test_tactics_jsonl_has_expected_tactics(tactics_jsonl_records):
    """Verify expected tactics are present in JSON Lines output."""
    tactics = {r["ppTac"] for r in tactics_jsonl_records}

    assert "rfl" in tactics or any("rfl" in t for t in tactics), \
        "Should have 'rfl' tactic in output"


def test_tactics_jsonl_no_output_directory_created():
    """Verify --jsonl flag does not create output directories."""
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        subprocess.run(
            ["lake", "run", "scout", "--command", "tactics", "--library",
             "LeanScoutTestProject", "--parallel", "1", "--jsonl",
             "--dataDir", str(data_dir)],
            capture_output=True,
            text=True,
            check=True,
            cwd=str(TEST_PROJECT_DIR)
        )

        tactics_dir = data_dir / "tactics"
        assert not tactics_dir.exists(), "--jsonl should not create output directory"
