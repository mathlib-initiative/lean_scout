"""Tests for CLI infrastructure.

This module tests the CLI's core functionality without extracting Lean data.
Tests focus on:
- File list reading
- Library path querying
"""
import tempfile
from pathlib import Path

import pytest

from lean_scout.cli import (
    query_library_paths,
    read_file_list,
    resolve_directories,
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


def test_read_file_list_resolves_base_path(tmp_path):
    file_list = tmp_path / "relative_list.txt"
    file_list.write_text("File1.lean\nFile2.lean\n")

    files = read_file_list("relative_list.txt", base_path=tmp_path)
    assert files == ["File1.lean", "File2.lean"]


def test_resolve_directories_defaults_to_root(tmp_path):
    root = (tmp_path / "project").resolve()
    root.mkdir()

    root_path, cmd_root, base_path = resolve_directories(
        root_path_arg=str(root),
        data_dir_arg=None,
        cmd_root_arg=str(root),
        command="types",
    )

    assert root_path == root
    assert cmd_root == root
    assert base_path == root / "types"


def test_resolve_directories_prefers_data_root_for_outputs(tmp_path):
    subproject = (tmp_path / "subproject").resolve()
    caller_root = (tmp_path / "caller").resolve()
    subproject.mkdir()
    caller_root.mkdir()

    _, cmd_root, base_path = resolve_directories(
        root_path_arg=str(subproject),
        data_dir_arg="outputs",
        cmd_root_arg=str(caller_root),
        command="tactics",
    )

    assert cmd_root == caller_root
    assert base_path == caller_root / "outputs" / "tactics"


def test_resolve_directories_respects_absolute_data_dir(tmp_path):
    subproject = (tmp_path / "subproject").resolve()
    data_root = (tmp_path / "caller").resolve()
    absolute_dir = (tmp_path / "absolute-out").resolve()
    subproject.mkdir()
    data_root.mkdir()
    absolute_dir.mkdir()

    _, resolved_cmd_root, base_path = resolve_directories(
        root_path_arg=str(subproject),
        data_dir_arg=str(absolute_dir),
        cmd_root_arg=str(data_root),
        command="types",
    )

    assert resolved_cmd_root == data_root
    assert base_path == absolute_dir / "types"
