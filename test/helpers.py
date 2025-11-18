"""Helper utilities for testing data extractors."""
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, cast
from datasets import Dataset
import glob


def extract_types(imports: str, data_dir: Path) -> Path:
    """
    Run the types extractor and return the output directory.

    Args:
        imports: Module to import (e.g., "Init", "Lean")
        data_dir: Base directory for output

    Returns:
        Path to the types subdirectory containing parquet files
    """
    subprocess.run(
        ["lake", "run", "scout", "--command", "types", "--dataDir", str(data_dir), "--imports", imports],
        capture_output=True,
        text=True,
        check=True
    )

    types_dir = data_dir / "types"
    if not types_dir.exists():
        raise RuntimeError(f"Types directory not created: {types_dir}")

    return types_dir


def extract_tactics(file_path: str, data_dir: Path) -> Path:
    """
    Run the tactics extractor and return the output directory.

    Args:
        file_path: Lean file to read (e.g., "LeanScoutTest/TacticsTest.lean")
        data_dir: Base directory for output

    Returns:
        Path to the tactics subdirectory containing parquet files
    """
    subprocess.run(
        ["lake", "run", "scout", "--command", "tactics", "--dataDir", str(data_dir), "--read", file_path],
        capture_output=True,
        text=True,
        check=True
    )

    tactics_dir = data_dir / "tactics"
    if not tactics_dir.exists():
        raise RuntimeError(f"Tactics directory not created: {tactics_dir}")

    return tactics_dir


def extract_from_library(command: str, library: str, data_dir: Path, parallel: int = 1) -> Path:
    """
    Run an extractor on all modules from a library using --library.

    Args:
        command: Extractor command (e.g., "types", "tactics")
        library: Library name (e.g., "LeanScoutTest", "Mathlib")
        data_dir: Base directory for output
        parallel: Number of parallel workers

    Returns:
        Path to the command subdirectory containing parquet files
    """
    subprocess.run(
        ["lake", "run", "scout", "--command", command, "--dataDir", str(data_dir),
         "--library", library, "--parallel", str(parallel)],
        capture_output=True,
        text=True,
        check=True
    )

    output_dir = data_dir / command
    if not output_dir.exists():
        raise RuntimeError(f"{command.capitalize()} directory not created: {output_dir}")

    return output_dir


def load_types_dataset(types_dir: Path) -> Dataset:
    """
    Load a types dataset from parquet files.

    Args:
        types_dir: Directory containing part-*.parquet files

    Returns:
        Dataset object with types data
    """
    parquet_files = glob.glob(str(types_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {types_dir}")

    # Type ignore for datasets library's strict PathLike typing
    return cast(Dataset, Dataset.from_parquet(parquet_files))  # type: ignore[arg-type]


def load_tactics_dataset(tactics_dir: Path) -> Dataset:
    """
    Load a tactics dataset from parquet files.

    Args:
        tactics_dir: Directory containing part-*.parquet files

    Returns:
        Dataset object with tactics data
    """
    parquet_files = glob.glob(str(tactics_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {tactics_dir}")

    # Type ignore for datasets library's strict PathLike typing
    return cast(Dataset, Dataset.from_parquet(parquet_files))  # type: ignore[arg-type]


def get_record_by_name(dataset: Dataset, name: str) -> Optional[Dict[str, Any]]:
    """
    Query dataset for a specific constant name.

    Args:
        dataset: Dataset to query
        name: Constant name to find

    Returns:
        Record dict if found, None otherwise
    """
    matches = dataset.filter(lambda x: x['name'] == name)

    if len(matches) == 0:
        return None

    if len(matches) > 1:
        raise RuntimeError(f"Multiple records found for name '{name}': {len(matches)}")

    return cast(Dict[str, Any], matches[0])


def get_records_by_module(dataset: Dataset, module: str) -> List[Dict[str, Any]]:
    """
    Query dataset for all constants in a specific module.

    Args:
        dataset: Dataset to query
        module: Module name to filter by

    Returns:
        List of record dicts
    """
    matches = dataset.filter(lambda x: x['module'] == module)
    return [cast(Dict[str, Any], matches[i]) for i in range(len(matches))]


def assert_record_exact_match(actual: Dict[str, Any], expected: Dict[str, Any]) -> None:
    """
    Assert that a record exactly matches expected values.

    Args:
        actual: Actual record from dataset
        expected: Expected field values

    Raises:
        AssertionError: If fields don't match
    """
    for key, expected_value in expected.items():
        if key not in actual:
            raise AssertionError(f"Field '{key}' not found in record")

        actual_value = actual[key]
        if actual_value != expected_value:
            raise AssertionError(
                f"Field '{key}' mismatch:\n"
                f"  Expected: {expected_value}\n"
                f"  Actual:   {actual_value}"
            )


def assert_record_contains(actual: Dict[str, Any], field: str, substring: str) -> None:
    """
    Assert that a record field contains a substring.

    Args:
        actual: Actual record from dataset
        field: Field name to check
        substring: Substring to look for

    Raises:
        AssertionError: If substring not found
    """
    if field not in actual:
        raise AssertionError(f"Field '{field}' not found in record")

    actual_value = actual[field]
    if actual_value is None:
        raise AssertionError(f"Field '{field}' is None, cannot check for substring")

    if substring not in str(actual_value):
        raise AssertionError(
            f"Field '{field}' does not contain '{substring}':\n"
            f"  Actual value: {actual_value}"
        )


def assert_record_not_null(actual: Dict[str, Any], field: str) -> None:
    """
    Assert that a record field is not null.

    Args:
        actual: Actual record from dataset
        field: Field name to check

    Raises:
        AssertionError: If field is null
    """
    if field not in actual:
        raise AssertionError(f"Field '{field}' not found in record")

    if actual[field] is None:
        raise AssertionError(f"Field '{field}' is None")


def get_records_by_tactic(dataset: Dataset, tactic: str) -> List[Dict[str, Any]]:
    """
    Query dataset for all records with a specific tactic.

    Args:
        dataset: Dataset to query
        tactic: Tactic string to filter by (ppTac field)

    Returns:
        List of record dicts
    """
    matches = dataset.filter(lambda x: x['ppTac'] == tactic)
    return [cast(Dict[str, Any], matches[i]) for i in range(len(matches))]


def get_records_by_tactic_contains(dataset: Dataset, substring: str) -> List[Dict[str, Any]]:
    """
    Query dataset for all records where ppTac contains a substring.

    Args:
        dataset: Dataset to query
        substring: Substring to search for in ppTac

    Returns:
        List of record dicts
    """
    matches = dataset.filter(lambda x: substring in x['ppTac'])
    return [cast(Dict[str, Any], matches[i]) for i in range(len(matches))]


def assert_tactic_exists(dataset: Dataset, tactic: str) -> None:
    """
    Assert that a specific tactic exists in the dataset.

    Args:
        dataset: Dataset to query
        tactic: Tactic string to look for

    Raises:
        AssertionError: If tactic not found
    """
    matches = get_records_by_tactic(dataset, tactic)
    if len(matches) == 0:
        raise AssertionError(f"Tactic not found: {tactic}")


def assert_tactic_contains(dataset: Dataset, substring: str, min_count: int = 1) -> None:
    """
    Assert that tactics containing a substring exist in the dataset.

    Args:
        dataset: Dataset to query
        substring: Substring to search for
        min_count: Minimum number of occurrences expected

    Raises:
        AssertionError: If not enough matches found
    """
    matches = get_records_by_tactic_contains(dataset, substring)
    if len(matches) < min_count:
        raise AssertionError(
            f"Expected at least {min_count} tactics containing '{substring}', "
            f"found {len(matches)}"
        )
