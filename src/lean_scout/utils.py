"""Utility functions for Lean Scout."""

import json
import logging
from collections.abc import Iterable, Iterator
from typing import Any, TextIO

import pyarrow as pa  # type: ignore[import-untyped]

logger = logging.getLogger(__name__)


def stream_json_lines(input_stream: Iterable[str] | TextIO) -> Iterator[dict[str, Any]]:
    """Stream and parse JSON lines from input, logging malformed lines as warnings.

    Terminates on EOF (stdin closed).
    """
    for line_num, line in enumerate(input_stream, start=1):
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError as e:
            # Log malformed JSON with truncated content for debugging
            line_preview = line[:100] + "..." if len(line) > 100 else line
            logger.warning(
                "Skipping malformed JSON at line %d: %s (error: %s)", line_num, line_preview, str(e)
            )


def datatype_from_json(type_obj: dict[str, Any]) -> pa.DataType:
    """Convert JSON type object to PyArrow DataType."""
    datatype = type_obj.get("datatype")
    if datatype == "bool":
        return pa.bool_()
    elif datatype == "nat":
        return pa.uint64()
    elif datatype == "int":
        return pa.int64()
    elif datatype == "float":
        return pa.float64()
    elif datatype == "string":
        return pa.string()
    elif datatype == "list":
        item = type_obj.get("item", {})
        item_datatype = datatype_from_json(item)
        return pa.list_(item_datatype)
    elif datatype == "struct":
        children = type_obj.get("children", [])
        fields = [field_from_json(child) for child in children]
        return pa.struct(fields)
    else:
        raise ValueError(f"Unknown datatype: {datatype}")


def field_from_json(field_obj: dict[str, Any]) -> pa.Field:
    """Convert JSON field object to PyArrow Field."""
    name = field_obj.get("name")
    nullable = field_obj.get("nullable", True)
    type_obj = field_obj.get("type", {})
    datatype = datatype_from_json(type_obj)
    return pa.field(name, datatype, nullable=nullable)


def schema_from_json(schema_obj: dict[str, Any]) -> pa.Schema:
    """Convert JSON schema object to PyArrow Schema."""
    fields = [field_from_json(field) for field in schema_obj.get("fields", [])]
    return pa.schema(fields)


def deserialize_schema(json_str: str) -> pa.Schema:
    """Deserialize PyArrow schema from JSON string."""
    schema_obj = json.loads(json_str)
    return schema_from_json(schema_obj)
