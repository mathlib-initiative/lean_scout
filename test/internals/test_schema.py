"""Tests for schema infrastructure.

This module tests generic schema functionality that doesn't depend on specific extractors.
"""
import subprocess


def test_schema_invalid_command():
    result = subprocess.run(
        ["lake", "exe", "-q", "lean_scout", "--command", "nonexistent", "--schema"],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0

    stderr_output = result.stderr.lower()
    assert "unknown" in stderr_output or "error" in stderr_output
