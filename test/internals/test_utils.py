"""Tests for utility functions (schema deserialization, JSON streaming)."""

import json
import logging

import pyarrow as pa
import pytest

from lean_scout.utils import (
    datatype_from_json,
    deserialize_schema,
    field_from_json,
    schema_from_json,
    stream_json_lines,
)


class TestStreamJsonLines:
    """Tests for stream_json_lines function."""

    def test_basic_json_lines(self):
        """Test parsing valid JSON lines."""
        lines = ['{"a": 1}', '{"b": 2}', '{"c": 3}']
        result = list(stream_json_lines(lines))
        assert result == [{"a": 1}, {"b": 2}, {"c": 3}]

    def test_empty_lines_skipped(self):
        """Test that empty lines are skipped."""
        lines = ['{"a": 1}', "", "  ", '{"b": 2}']
        result = list(stream_json_lines(lines))
        assert result == [{"a": 1}, {"b": 2}]

    def test_malformed_json_logged_and_skipped(self, caplog):
        """Test that malformed JSON is logged and skipped."""
        lines = ['{"a": 1}', "not valid json", '{"b": 2}']
        with caplog.at_level(logging.WARNING):
            result = list(stream_json_lines(lines))

        assert result == [{"a": 1}, {"b": 2}]
        assert "malformed JSON" in caplog.text
        assert "line 2" in caplog.text

    def test_long_malformed_line_truncated_in_log(self, caplog):
        """Test that long malformed lines are truncated in log output."""
        long_invalid = "x" * 200
        lines = [long_invalid]
        with caplog.at_level(logging.WARNING):
            result = list(stream_json_lines(lines))

        assert result == []
        assert "..." in caplog.text  # Line was truncated

    def test_whitespace_stripped(self):
        """Test that whitespace is stripped from lines."""
        lines = ['  {"a": 1}  ', '\t{"b": 2}\n']
        result = list(stream_json_lines(lines))
        assert result == [{"a": 1}, {"b": 2}]


class TestDatatypeFromJson:
    """Tests for datatype_from_json function."""

    def test_bool_type(self):
        """Test boolean datatype conversion."""
        result = datatype_from_json({"datatype": "bool"})
        assert result == pa.bool_()

    def test_nat_type(self):
        """Test natural number (uint64) datatype conversion."""
        result = datatype_from_json({"datatype": "nat"})
        assert result == pa.uint64()

    def test_int_type(self):
        """Test integer (int64) datatype conversion."""
        result = datatype_from_json({"datatype": "int"})
        assert result == pa.int64()

    def test_float_type(self):
        """Test float (float64) datatype conversion."""
        result = datatype_from_json({"datatype": "float"})
        assert result == pa.float64()

    def test_string_type(self):
        """Test string datatype conversion."""
        result = datatype_from_json({"datatype": "string"})
        assert result == pa.string()

    def test_list_type(self):
        """Test list datatype conversion."""
        result = datatype_from_json({
            "datatype": "list",
            "item": {"datatype": "string"}
        })
        assert result == pa.list_(pa.string())

    def test_struct_type(self):
        """Test struct datatype conversion."""
        result = datatype_from_json({
            "datatype": "struct",
            "children": [
                {"name": "x", "type": {"datatype": "int"}},
                {"name": "y", "type": {"datatype": "float"}},
            ]
        })
        expected = pa.struct([
            pa.field("x", pa.int64(), nullable=True),
            pa.field("y", pa.float64(), nullable=True),
        ])
        assert result == expected

    def test_nested_list_of_struct(self):
        """Test nested list of struct datatype."""
        result = datatype_from_json({
            "datatype": "list",
            "item": {
                "datatype": "struct",
                "children": [
                    {"name": "id", "type": {"datatype": "string"}},
                ]
            }
        })
        expected = pa.list_(pa.struct([
            pa.field("id", pa.string(), nullable=True),
        ]))
        assert result == expected

    def test_unknown_datatype_raises(self):
        """Test that unknown datatype raises ValueError."""
        with pytest.raises(ValueError, match="Unknown datatype"):
            datatype_from_json({"datatype": "unknown"})


class TestFieldFromJson:
    """Tests for field_from_json function."""

    def test_basic_field(self):
        """Test basic field conversion."""
        result = field_from_json({
            "name": "myfield",
            "type": {"datatype": "string"}
        })
        assert result.name == "myfield"
        assert result.type == pa.string()
        assert result.nullable is True  # default

    def test_non_nullable_field(self):
        """Test non-nullable field conversion."""
        result = field_from_json({
            "name": "required",
            "nullable": False,
            "type": {"datatype": "int"}
        })
        assert result.name == "required"
        assert result.type == pa.int64()
        assert result.nullable is False


class TestSchemaFromJson:
    """Tests for schema_from_json function."""

    def test_empty_schema(self):
        """Test empty schema conversion."""
        result = schema_from_json({"fields": []})
        assert len(result) == 0

    def test_multi_field_schema(self):
        """Test schema with multiple fields."""
        result = schema_from_json({
            "fields": [
                {"name": "a", "type": {"datatype": "string"}},
                {"name": "b", "nullable": False, "type": {"datatype": "int"}},
            ]
        })
        assert len(result) == 2
        assert result.field("a").type == pa.string()
        assert result.field("b").type == pa.int64()
        assert result.field("b").nullable is False


class TestDeserializeSchema:
    """Tests for deserialize_schema function."""

    def test_full_roundtrip(self):
        """Test deserializing a complete schema from JSON string."""
        schema_json = json.dumps({
            "fields": [
                {"name": "name", "nullable": False, "type": {"datatype": "string"}},
                {"name": "count", "type": {"datatype": "nat"}},
                {"name": "tags", "type": {"datatype": "list", "item": {"datatype": "string"}}},
            ]
        })
        result = deserialize_schema(schema_json)

        assert len(result) == 3
        assert result.field("name").type == pa.string()
        assert result.field("name").nullable is False
        assert result.field("count").type == pa.uint64()
        assert result.field("tags").type == pa.list_(pa.string())

    def test_invalid_json_raises(self):
        """Test that invalid JSON raises an exception."""
        with pytest.raises(json.JSONDecodeError):
            deserialize_schema("not valid json")
