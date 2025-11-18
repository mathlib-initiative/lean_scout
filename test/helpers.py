"""Helper utilities for testing data extractors."""
import subprocess
from pathlib import Path
from datasets import Dataset
import glob
import pytest


TEST_PROJECT_DIR = Path(__file__).parent.parent / "test_project"


@pytest.fixture(scope="module", autouse=True)
def build_test_project():
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


def extract_from_dependency_library(command: str, library: str, data_dir: Path,
                                     working_dir: Path, parallel: int = 1) -> Path:
    subprocess.run(
        ["lake", "run", "scout", "--command", command, "--dataDir", str(data_dir),
         "--library", library, "--parallel", str(parallel)],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(working_dir)
    )

    output_dir = data_dir / command
    if not output_dir.exists():
        raise RuntimeError(f"{command.capitalize()} directory not created: {output_dir}")

    return output_dir


def load_types_dataset(types_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(types_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {types_dir}")

    return Dataset.from_parquet(parquet_files)  # type: ignore[arg-type]


def load_tactics_dataset(tactics_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {tactics_dir}")

    return Dataset.from_parquet(parquet_files)  # type: ignore[arg-type]


def get_record_by_name(dataset: Dataset, name: str):
    matches = dataset.filter(lambda x: x['name'] == name)

    if len(matches) == 0:
        return None

    if len(matches) > 1:
        raise RuntimeError(f"Multiple records found for name '{name}'")

    return matches[0]


def get_records_by_tactic(dataset: Dataset, tactic: str):
    matches = dataset.filter(lambda x: x['ppTac'] == tactic)
    return [matches[i] for i in range(len(matches))]


def get_records_by_tactic_contains(dataset: Dataset, substring: str):
    matches = dataset.filter(lambda x: substring in x['ppTac'])
    return [matches[i] for i in range(len(matches))]


def assert_record_exact_match(actual, expected):
    for key, expected_value in expected.items():
        assert key in actual, f"Field '{key}' not found in record"
        actual_value = actual[key]
        assert actual_value == expected_value, (
            f"Field '{key}' mismatch:\n"
            f"  Expected: {expected_value}\n"
            f"  Actual:   {actual_value}"
        )


def assert_record_contains(actual, field: str, substring: str):
    assert field in actual, f"Field '{field}' not found in record"
    actual_value = actual[field]
    assert actual_value is not None, f"Field '{field}' is None"
    assert substring in str(actual_value), (
        f"Field '{field}' does not contain '{substring}':\n"
        f"  Actual value: {actual_value}"
    )


def assert_record_not_null(actual, field: str):
    assert field in actual, f"Field '{field}' not found in record"
    assert actual[field] is not None, f"Field '{field}' is None"


def assert_tactic_contains(dataset: Dataset, substring: str, min_count: int = 1):
    matches = get_records_by_tactic_contains(dataset, substring)
    assert len(matches) >= min_count, (
        f"Expected at least {min_count} tactics containing '{substring}', "
        f"found {len(matches)}"
    )
