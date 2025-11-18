"""Tests for --library functionality."""
import pytest
import tempfile
import subprocess
from pathlib import Path
from datasets import Dataset
import glob

from helpers import extract_from_library, load_tactics_dataset


# Unit tests for query_library_paths function


def test_query_library_paths_leanscouttest():
    """
    Test that query_library_paths can query LeanScoutTest module paths.

    This tests the underlying lake query functionality.
    """
    from lean_scout.cli import query_library_paths

    scout_path = Path(".").resolve()
    paths = query_library_paths("LeanScoutTest", scout_path)

    # Should return a list of file paths
    assert isinstance(paths, list), "Should return a list"
    assert len(paths) > 0, "Should find at least one module"

    # All paths should be strings
    assert all(isinstance(p, str) for p in paths), "All paths should be strings"

    # All paths should end with .lean
    assert all(p.endswith(".lean") for p in paths), "All paths should be .lean files"

    # Should include known test files
    path_basenames = [Path(p).name for p in paths]
    assert "TacticsTest.lean" in path_basenames, "Should include TacticsTest.lean"


def test_query_library_paths_nonexistent():
    """
    Test that query_library_paths raises error for nonexistent library.
    """
    from lean_scout.cli import query_library_paths

    scout_path = Path(".").resolve()

    with pytest.raises(RuntimeError) as exc_info:
        query_library_paths("NonexistentLibrary", scout_path)

    assert "Failed to query module paths" in str(exc_info.value)


def test_lake_query_command_directly():
    """
    Test that lake query command works directly.

    This ensures the module_paths facet is working correctly.
    """
    result = subprocess.run(
        ["lake", "query", "-q", "LeanScoutTest:module_paths"],
        capture_output=True,
        text=True,
        check=True
    )

    assert result.returncode == 0, "lake query should succeed"
    assert len(result.stdout) > 0, "Should output module paths"

    # Parse output
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    assert len(lines) > 0, "Should have at least one module path"
    assert all(line.endswith(".lean") for line in lines), "All paths should be .lean files"


# Integration tests for --library CLI option


@pytest.fixture(scope="module")
def query_library_tactics_dataset():
    """
    Extract tactics from LeanScoutTest library using --library.

    This fixture tests the full --library flow with parallel extraction.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Use the helper function
        tactics_dir = extract_from_library("tactics", "LeanScoutTest", data_dir, parallel=2)

        # Load dataset
        dataset = load_tactics_dataset(tactics_dir)
        yield dataset


def test_query_library_extraction_success(query_library_tactics_dataset):
    """
    Test that --library successfully extracts data.

    Verifies that the extraction produces a non-empty dataset.
    """
    dataset = query_library_tactics_dataset

    assert len(dataset) > 0, "Dataset should not be empty"
    assert len(dataset) >= 6, f"Expected at least 6 tactics from test files, got {len(dataset)}"


def test_query_library_schema(query_library_tactics_dataset):
    """
    Test that --library maintains correct schema.

    Verifies that all expected fields are present with correct types.
    """
    dataset = query_library_tactics_dataset

    # Verify schema
    assert 'goals' in dataset.column_names, "Missing 'goals' field"
    assert 'ppTac' in dataset.column_names, "Missing 'ppTac' field"

    # Check first record
    first_record = dataset[0]
    assert isinstance(first_record['goals'], list), "'goals' should be a list"
    assert isinstance(first_record['ppTac'], str), "'ppTac' should be a string"


def test_query_library_specific_tactics(query_library_tactics_dataset):
    """
    Test that specific expected tactics from test files are present.

    Verifies that tactics from the LeanScoutTest modules appear in output.
    """
    dataset = query_library_tactics_dataset

    # Get all tactics
    all_tactics = set(dataset['ppTac'])

    # Check for expected tactics from test files
    assert 'rfl' in all_tactics, "Expected 'rfl' tactic to be present"


def test_query_library_vs_read_list_equivalence():
    """
    Test that --library produces equivalent results to --read-list.

    This verifies that the new feature correctly processes all module files.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # First, use query-library
        query_result = subprocess.run(
            ["lake", "query", "-q", "LeanScoutTest:module_paths"],
            capture_output=True,
            text=True,
            check=True
        )
        file_paths = [line.strip() for line in query_result.stdout.splitlines() if line.strip()]

        # Create a file list
        file_list_path = data_dir / "file_list.txt"
        with open(file_list_path, 'w') as f:
            for path in file_paths:
                f.write(f"{path}\n")

        # Extract using --read-list
        tactics_dir_read_list = data_dir / "tactics_read_list"
        tactics_dir_read_list.mkdir(parents=True)
        subprocess.run(
            ["lake", "run", "scout", "--command", "tactics",
             "--dataDir", str(tactics_dir_read_list), "--read-list", str(file_list_path),
             "--parallel", "2"],
            capture_output=True,
            text=True,
            check=True
        )

        # Extract using --library
        tactics_dir_query = data_dir / "tactics_query"
        tactics_dir_query.mkdir(parents=True)
        subprocess.run(
            ["lake", "run", "scout", "--command", "tactics",
             "--dataDir", str(tactics_dir_query), "--library", "LeanScoutTest",
             "--parallel", "2"],
            capture_output=True,
            text=True,
            check=True
        )

        # Load both datasets
        read_list_files = glob.glob(str(tactics_dir_read_list / "tactics" / "*.parquet"))
        query_files = glob.glob(str(tactics_dir_query / "tactics" / "*.parquet"))

        dataset_read_list = Dataset.from_parquet(read_list_files)
        dataset_query = Dataset.from_parquet(query_files)

        # Both should have same number of records
        assert len(dataset_read_list) == len(dataset_query), \
            f"Both methods should produce same number of records: {len(dataset_read_list)} vs {len(dataset_query)}"

        # Both should have same tactics (though possibly different order)
        tactics_read_list = sorted(dataset_read_list['ppTac'])
        tactics_query = sorted(dataset_query['ppTac'])
        assert tactics_read_list == tactics_query, \
            "Both methods should produce same tactics"


def test_query_library_parallel_processing():
    """
    Test that --library respects --parallel flag.

    Verifies that parallel processing works correctly with library extraction.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Run with parallel=4
        result = subprocess.run(
            ["lake", "run", "scout", "--command", "tactics",
             "--dataDir", str(data_dir), "--library", "LeanScoutTest",
             "--parallel", "4"],
            capture_output=True,
            text=True,
            check=True
        )

        # Check output mentions parallel processing
        assert "parallel" in result.stderr.lower() or "workers" in result.stderr.lower(), \
            "Output should mention parallel processing"

        # Verify dataset was created
        tactics_dir = data_dir / "tactics"
        assert tactics_dir.exists(), "Tactics directory should be created"

        parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
        assert len(parquet_files) > 0, "Should create parquet files"

        dataset = Dataset.from_parquet(parquet_files)
        assert len(dataset) > 0, "Dataset should not be empty"


def test_query_library_extractor_compatibility():
    """
    Test that --library correctly handles unsupported extractors.

    The types extractor only supports --imports, not --read targets.
    This test verifies appropriate error handling for unsupported combinations.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Try to use types extractor with library (should fail)
        result = subprocess.run(
            ["lake", "run", "scout", "--command", "types",
             "--dataDir", str(data_dir), "--library", "LeanScoutTest"],
            capture_output=True,
            text=True,
        )

        # Should fail because types extractor doesn't support read targets
        assert result.returncode != 0, "Types extractor should fail with --library"
        assert "Unsupported Target" in result.stderr, \
            "Error should mention unsupported target"


def test_query_library_error_handling():
    """
    Test that --library handles errors gracefully.

    Verifies appropriate error messages for invalid library names.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        # Try to query nonexistent library
        result = subprocess.run(
            ["lake", "run", "scout", "--command", "tactics",
             "--dataDir", str(data_dir), "--library", "NonexistentLibrary"],
            capture_output=True,
            text=True,
        )

        # Should fail with error
        assert result.returncode != 0, "Should fail for nonexistent library"
        assert "Failed to query" in result.stderr or "error" in result.stderr.lower(), \
            "Error message should mention query failure"


def test_query_library_determinism():
    """
    Test that --library produces deterministic results.

    Running the same extraction twice should produce the same data
    (though possibly in different order due to parallel execution).
    """
    # Run extraction twice
    datasets = []
    for _ in range(2):
        with tempfile.TemporaryDirectory() as tmpdir:
            data_dir = Path(tmpdir)

            tactics_dir = extract_from_library("tactics", "LeanScoutTest", data_dir, parallel=2)
            dataset = load_tactics_dataset(tactics_dir)
            datasets.append(dataset)

    # Both runs should produce same number of records
    assert len(datasets[0]) == len(datasets[1]), \
        f"Extraction should be deterministic: {len(datasets[0])} vs {len(datasets[1])}"

    # Both runs should have same tactics (though possibly different order)
    tactics1 = sorted(datasets[0]['ppTac'])
    tactics2 = sorted(datasets[1]['ppTac'])
    assert tactics1 == tactics2, "Extraction should produce same tactics"
