"""Helper utilities for testing data extractors."""
import subprocess
import json
from pathlib import Path
from datasets import Dataset
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


def get_record_by_name(dataset: Dataset, name: str):
    matches = dataset.filter(lambda x: x['name'] == name)

    if len(matches) == 0:
        return None

    if len(matches) > 1:
        raise RuntimeError(f"Multiple records found for name '{name}'")

    return matches[0]


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


def get_schema_json(command: str) -> dict:
    """Query Lean for schema JSON of a given command."""
    result = subprocess.run(
        ["lake", "exe", "lean_scout", "--command", command, "--schema"],
        capture_output=True,
        text=True,
        check=True,
    )

    schema_json = result.stdout.strip()
    if not schema_json:
        raise RuntimeError(f"No schema output for command '{command}'")

    return json.loads(schema_json)
