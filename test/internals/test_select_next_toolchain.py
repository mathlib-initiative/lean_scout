"""Tests for the step-by-step Lean toolchain updater."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from types import ModuleType

SCRIPT_PATH = Path(__file__).parents[2] / ".github" / "scripts" / "select-next-toolchain.py"


def load_script() -> ModuleType:
    """Load the updater script as a module despite its hyphenated filename."""
    spec = importlib.util.spec_from_file_location("select_next_toolchain", SCRIPT_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def updater() -> ModuleType:
    """Return the loaded updater module."""
    return load_script()


def test_selects_patch_before_newer_minor_release(updater: ModuleType) -> None:
    releases = [
        "v4.33.0-rc2",
        "v4.32.2",
        "v4.33.0-rc1",
        "v4.32.1",
        "v4.32.0",
    ]

    assert updater.select_next_version("v4.32.0", releases) == "v4.32.1"
    assert updater.select_next_version("v4.32.1", releases) == "v4.32.2"
    assert updater.select_next_version("v4.32.2", releases) == "v4.33.0-rc1"


def test_orders_release_candidates_before_stable_release(updater: ModuleType) -> None:
    releases = ["v4.33.0", "v4.33.0-rc2", "v4.33.0-rc1"]

    assert updater.select_next_version("v4.32.2", releases) == "v4.33.0-rc1"
    assert updater.select_next_version("v4.33.0-rc1", releases) == "v4.33.0-rc2"
    assert updater.select_next_version("v4.33.0-rc2", releases) == "v4.33.0"


def test_returns_none_at_newest_release(updater: ModuleType) -> None:
    assert updater.select_next_version("v4.32.2", ["v4.32.1", "v4.32.2"]) is None


def test_ignores_non_release_tags(updater: ModuleType) -> None:
    releases = ["nightly-2026-07-28", "v4.33.0-beta1", "v4.32.1"]

    assert updater.select_next_version("v4.32.0", releases) == "v4.32.1"


def test_advance_toolchain_preserves_newline(updater: ModuleType, tmp_path: Path) -> None:
    toolchain = tmp_path / "lean-toolchain"
    toolchain.write_text("leanprover/lean4:v4.32.0\n", encoding="utf-8")

    selected = updater.advance_toolchain(toolchain, ["v4.33.0-rc1", "v4.32.1"])

    assert selected == "v4.32.1"
    assert toolchain.read_text(encoding="utf-8") == "leanprover/lean4:v4.32.1\n"


def test_rejects_unexpected_current_toolchain(updater: ModuleType) -> None:
    with pytest.raises(ValueError, match="unsupported current Lean version"):
        updater.select_next_version("nightly-2026-07-28", ["v4.32.1"])
