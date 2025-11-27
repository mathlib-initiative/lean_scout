"""Shared fixtures for extractor tests."""
import subprocess
from pathlib import Path

import pytest

TEST_PROJECT_DIR = Path(__file__).parent.parent.parent / "test_project"


@pytest.fixture(scope="module", autouse=True)
def build_test_project():
    """Build the test project before running extractor tests."""
    result = subprocess.run(
        ["lake", "-q", "build"],
        cwd=str(TEST_PROJECT_DIR),
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Failed to build test project:\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
