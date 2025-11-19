"""Tests for CLI infrastructure.

This module tests the CLI's core functionality without extracting Lean data.
Tests focus on:
- File list reading
- Library path querying
"""
import pytest
import tempfile
from pathlib import Path

from lean_scout.cli import (
    read_file_list,
    query_library_paths,
)


def test_read_file_list_valid():
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
        f.write("File1.lean\n")
        f.write("File2.lean\n")
        f.write("\n")
        f.write("  File3.lean  \n")
        f.write("File4.lean\n")
        temp_path = f.name

    try:
        files = read_file_list(temp_path)

        assert len(files) == 4
        assert "File1.lean" in files
        assert "File2.lean" in files
        assert "File3.lean" in files
        assert "File4.lean" in files
    finally:
        Path(temp_path).unlink()


def test_read_file_list_empty():
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
        f.write("\n\n\n")
        temp_path = f.name

    try:
        with pytest.raises(RuntimeError, match="File list is empty"):
            read_file_list(temp_path)
    finally:
        Path(temp_path).unlink()


def test_read_file_list_not_found():
    with pytest.raises(FileNotFoundError, match="File list not found"):
        read_file_list("/nonexistent/file.txt")


def test_query_library_paths_success():
    test_project_dir = Path(__file__).parent.parent.parent / "test_project"
    files = query_library_paths("LeanScoutTestProject", test_project_dir)

    assert len(files) > 0
    assert any("Basic.lean" in f for f in files)
    assert any("Lists.lean" in f for f in files)


def test_query_library_paths_failure():
    test_project_dir = Path(__file__).parent.parent.parent / "test_project"

    with pytest.raises(RuntimeError, match="Failed to query module paths"):
        query_library_paths("NonexistentLib", test_project_dir)


def test_read_file_list_whitespace_handling():
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
        f.write("  File1.lean  \n")
        f.write("\tFile2.lean\n")
        f.write("File3.lean\r\n")
        f.write("   \n")
        f.write("\t\t\n")
        temp_path = f.name

    try:
        files = read_file_list(temp_path)

        assert len(files) == 3
        assert files[0] == "File1.lean"
        assert files[1] == "File2.lean"
        assert files[2] == "File3.lean"
    finally:
        Path(temp_path).unlink()
