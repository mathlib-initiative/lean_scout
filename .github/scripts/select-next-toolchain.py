#!/usr/bin/env python3
"""Advance lean-toolchain to the next published Lean release."""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterable

LEAN_RELEASES_ENDPOINT = "repos/leanprover/lean4/releases?per_page=100"
TOOLCHAIN_PREFIX = "leanprover/lean4:"
VERSION_PATTERN = re.compile(
    r"^v(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)"
    r"(?:-rc(?P<release_candidate>\d+))?$"
)


@dataclass(frozen=True)
class LeanVersion:
    """A stable or release-candidate Lean version."""

    tag: str
    major: int
    minor: int
    patch: int
    release_candidate: int | None

    @property
    def ordering_key(self) -> tuple[int, int, int, int, int]:
        """Return a SemVer-compatible key for Lean stable and RC releases."""
        is_stable = int(self.release_candidate is None)
        rc_number = self.release_candidate or 0
        return (self.major, self.minor, self.patch, is_stable, rc_number)


@dataclass(frozen=True)
class LeanRelease:
    """A Lean release and the time GitHub published it."""

    tag: str
    published_at: datetime


def parse_lean_version(tag: str) -> LeanVersion | None:
    """Parse a Lean stable or RC release tag, ignoring other tag formats."""
    match = VERSION_PATTERN.fullmatch(tag)
    if match is None:
        return None

    rc = match.group("release_candidate")
    return LeanVersion(
        tag=tag,
        major=int(match.group("major")),
        minor=int(match.group("minor")),
        patch=int(match.group("patch")),
        release_candidate=int(rc) if rc is not None else None,
    )


def select_next_version(current_tag: str, releases: Iterable[LeanRelease]) -> str | None:
    """Select the first Lean release published after ``current_tag``."""
    current = parse_lean_version(current_tag)
    if current is None:
        raise ValueError(f"unsupported current Lean version: {current_tag}")

    parsed_releases = [
        (release, version)
        for release in releases
        if (version := parse_lean_version(release.tag)) is not None
    ]
    current_releases = [
        release for release, version in parsed_releases if version.tag == current.tag
    ]
    if not current_releases:
        raise ValueError(f"current Lean release not found: {current_tag}")

    current_published_at = max(release.published_at for release in current_releases)
    later_releases = [
        (release, version)
        for release, version in parsed_releases
        if release.published_at > current_published_at
    ]
    if not later_releases:
        return None

    _, next_version = min(
        later_releases,
        key=lambda item: (item[0].published_at, item[1].ordering_key),
    )
    return next_version.tag


def fetch_releases() -> list[LeanRelease]:
    """Fetch published Lean releases and timestamps through the GitHub CLI."""
    result = subprocess.run(
        [
            "gh",
            "api",
            "--paginate",
            LEAN_RELEASES_ENDPOINT,
            "--jq",
            '.[] | select(.draft == false) | [.published_at, .tag_name] | @tsv',
        ],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    releases = []
    for line in result.stdout.splitlines():
        published_at, tag = line.split("\t", maxsplit=1)
        releases.append(
            LeanRelease(
                tag=tag,
                published_at=datetime.fromisoformat(published_at.replace("Z", "+00:00")),
            )
        )
    return releases


def advance_toolchain(toolchain_path: Path, releases: Iterable[LeanRelease]) -> str | None:
    """Advance ``toolchain_path`` by one release and return the selected tag."""
    contents = toolchain_path.read_text(encoding="utf-8")
    toolchain = contents.strip()
    if not toolchain.startswith(TOOLCHAIN_PREFIX):
        raise ValueError(f"unexpected lean-toolchain contents: {toolchain}")

    current_tag = toolchain.removeprefix(TOOLCHAIN_PREFIX)
    next_tag = select_next_version(current_tag, releases)
    if next_tag is None:
        return None

    trailing_newline = "\n" if contents.endswith("\n") else ""
    toolchain_path.write_text(f"{TOOLCHAIN_PREFIX}{next_tag}{trailing_newline}", encoding="utf-8")
    return next_tag


def main() -> int:
    """Advance the repository toolchain by exactly one published release."""
    toolchain_path = Path("lean-toolchain")
    current = toolchain_path.read_text(encoding="utf-8").strip()
    next_tag = advance_toolchain(toolchain_path, fetch_releases())
    if next_tag is None:
        print(f"{current} is already at the newest published Lean release.")
    else:
        print(f"Advanced {current} to {TOOLCHAIN_PREFIX}{next_tag}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Failed to select the next Lean release: {error}", file=sys.stderr)
        sys.exit(1)
