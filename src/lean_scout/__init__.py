"""Lean Scout - A tool for creating datasets from Lean4 projects.

This package provides tools for extracting structured data from Lean4 projects.

Architecture:
    Python orchestrates Lean subprocess(es) that extract data and output JSON.
    The orchestrator feeds JSON to a writer.
"""

from .utils import (
    deserialize_schema,
    stream_json_lines,
)
from .writer import ShardedParquetWriter

__all__ = [
    "ShardedParquetWriter",
    "deserialize_schema",
    "stream_json_lines",
]
