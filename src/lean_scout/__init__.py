"""Lean Scout - A tool for creating datasets from Lean4 projects.

This package provides tools for extracting structured data from Lean4 projects
and storing them as sharded Parquet files.

Architecture:
    Python orchestrates Lean subprocess(es) that extract data and output JSON.
    The orchestrator feeds JSON to a shared pool of Parquet writers for efficient
    parallel extraction.
"""

from .utils import (
    deserialize_schema,
    load_schema,
    stream_json_lines,
)

from .writer import (
    ShardedParquetWriter,
)

from .orchestrator import (
    Orchestrator,
)

__all__ = [
    "deserialize_schema",
    "load_schema",
    "stream_json_lines",
    "ShardedParquetWriter",
    "Orchestrator",
]
