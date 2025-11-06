"""Helper utilities for testing data extractors."""
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional
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

    return Dataset.from_parquet(parquet_files)


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

    return matches[0]


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
    return [matches[i] for i in range(len(matches))]


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
