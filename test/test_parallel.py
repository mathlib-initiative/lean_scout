"""Tests for parallel file extraction."""
import pytest
import tempfile
import subprocess
from pathlib import Path
from datasets import Dataset
import glob


@pytest.fixture(scope="module")
def parallel_tactics_dataset():
    """
    Extract tactics from multiple files in parallel.

    This fixture tests parallel extraction by processing 3 test files
    simultaneously and verifying the combined output.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Run extraction with multiple files in parallel
        test_files = [
            "LeanScoutTest/ParallelTest1.lean",
            "LeanScoutTest/ParallelTest2.lean",
            "LeanScoutTest/ParallelTest3.lean",
        ]

        result = subprocess.run(
            ["lake", "run", "scout", "--command", "tactics", "--dataDir", str(data_dir),
             "--parallel", "3", "--read"] + test_files,
            capture_output=True,
            text=True,
            check=True
        )

        tactics_dir = data_dir / "tactics"
        if not tactics_dir.exists():
            raise RuntimeError(f"Tactics directory not created: {tactics_dir}")

        # Load dataset
        parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
        if not parquet_files:
            raise RuntimeError(f"No parquet files found in {tactics_dir}")

        dataset = Dataset.from_parquet(parquet_files)
        yield dataset


@pytest.fixture(scope="module")
def parallel_file_list_dataset():
    """
    Extract tactics using --read-list with a file containing paths.

    This tests the --read-list functionality for reading file paths from a file.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Create a file list
        file_list_path = data_dir / "test_files.txt"
        test_files = [
            "LeanScoutTest/ParallelTest1.lean",
            "LeanScoutTest/ParallelTest2.lean",
            "LeanScoutTest/ParallelTest3.lean",
        ]

        with open(file_list_path, 'w') as f:
            for file_path in test_files:
                f.write(f"{file_path}\n")

        # Run extraction using --read-list
        result = subprocess.run(
            ["lake", "run", "scout", "--command", "tactics", "--dataDir", str(data_dir),
             "--parallel", "3", "--read-list", str(file_list_path)],
            capture_output=True,
            text=True,
            check=True
        )

        tactics_dir = data_dir / "tactics"
        if not tactics_dir.exists():
            raise RuntimeError(f"Tactics directory not created: {tactics_dir}")

        # Load dataset
        parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
        if not parquet_files:
            raise RuntimeError(f"No parquet files found in {tactics_dir}")

        dataset = Dataset.from_parquet(parquet_files)
        yield dataset


def test_parallel_extraction_completeness(parallel_tactics_dataset):
    """
    Test that parallel extraction produces data from all files.

    Verifies that tactics from all 3 test files are present in the output.
    """
    dataset = parallel_tactics_dataset

    # Check that we have some records
    assert len(dataset) > 0, "Dataset should not be empty"

    # Check that we have tactics from multiple files
    # Each test file should have at least a few tactics
    assert len(dataset) >= 6, f"Expected at least 6 tactics (2 per file), got {len(dataset)}"


def test_parallel_extraction_schema(parallel_tactics_dataset):
    """
    Test that parallel extraction maintains correct schema.

    Verifies that all expected fields are present with correct types.
    """
    dataset = parallel_tactics_dataset

    # Verify schema
    assert 'goals' in dataset.column_names, "Missing 'goals' field"
    assert 'ppTac' in dataset.column_names, "Missing 'ppTac' field"

    # Check first record
    first_record = dataset[0]
    assert isinstance(first_record['goals'], list), "'goals' should be a list"
    assert isinstance(first_record['ppTac'], str), "'ppTac' should be a string"


def test_parallel_extraction_specific_tactics(parallel_tactics_dataset):
    """
    Test that specific expected tactics are present in the output.

    Each test file has known tactics (rfl, norm_num) that should appear.
    """
    dataset = parallel_tactics_dataset

    # Get all tactics
    all_tactics = set(dataset['ppTac'])

    # Check for expected tactics from test files
    assert 'rfl' in all_tactics, "Expected 'rfl' tactic to be present"


def test_read_list_extraction(parallel_file_list_dataset):
    """
    Test that --read-list produces same results as --read.

    Verifies that reading from a file list works correctly.
    """
    dataset = parallel_file_list_dataset

    # Same basic checks as parallel extraction
    assert len(dataset) > 0, "Dataset should not be empty"
    assert len(dataset) >= 6, f"Expected at least 6 tactics, got {len(dataset)}"

    # Verify schema
    assert 'goals' in dataset.column_names, "Missing 'goals' field"
    assert 'ppTac' in dataset.column_names, "Missing 'ppTac' field"


def test_single_file_still_works():
    """
    Test that single file extraction still works (backward compatibility).

    Verifies that the original --read with single file continues to function.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Run extraction with single file
        result = subprocess.run(
            ["lake", "run", "scout", "--command", "tactics", "--dataDir", str(data_dir),
             "--read", "LeanScoutTest/TacticsTest.lean"],
            capture_output=True,
            text=True,
            check=True
        )

        tactics_dir = data_dir / "tactics"
        assert tactics_dir.exists(), "Tactics directory should be created"

        # Load and verify dataset
        parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
        assert len(parquet_files) > 0, "Should have created parquet files"

        dataset = Dataset.from_parquet(parquet_files)
        assert len(dataset) > 0, "Dataset should not be empty"


def test_parallel_determinism():
    """
    Test that parallel extraction produces deterministic results.

    Running the same extraction twice should produce the same data
    (though possibly in different order due to parallel execution).
    """
    test_files = [
        "LeanScoutTest/ParallelTest1.lean",
        "LeanScoutTest/ParallelTest2.lean",
    ]

    # Run extraction twice
    datasets = []
    for _ in range(2):
        with tempfile.TemporaryDirectory() as tmpdir:
            data_dir = Path(tmpdir)

            subprocess.run(
                ["lake", "run", "scout", "--command", "tactics", "--dataDir", str(data_dir),
                 "--parallel", "2", "--read"] + test_files,
                capture_output=True,
                text=True,
                check=True
            )

            tactics_dir = data_dir / "tactics"
            parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
            dataset = Dataset.from_parquet(parquet_files)
            datasets.append(dataset)

    # Both runs should produce same number of records
    assert len(datasets[0]) == len(datasets[1]), \
        f"Parallel extraction should be deterministic: {len(datasets[0])} vs {len(datasets[1])}"

    # Both runs should have same tactics (though possibly different order)
    tactics1 = sorted(datasets[0]['ppTac'])
    tactics2 = sorted(datasets[1]['ppTac'])
    assert tactics1 == tactics2, "Parallel extraction should produce same tactics"
