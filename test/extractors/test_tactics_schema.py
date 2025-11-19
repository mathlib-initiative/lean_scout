"""Tests for tactics extractor schema."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import get_schema_json
from lean_scout.utils import deserialize_schema


def test_tactics_schema_structure():
    schema = get_schema_json("tactics")

    assert "fields" in schema
    assert "key" in schema

    assert isinstance(schema["fields"], list)
    assert len(schema["fields"]) > 0

    assert isinstance(schema["key"], str)

    for field in schema["fields"]:
        assert "name" in field
        assert "type" in field
        assert "nullable" in field

    field_names = [f["name"] for f in schema["fields"]]
    assert "ppTac" in field_names


def test_tactics_schema_deserialization():
    schema_dict = get_schema_json("tactics")
    schema_json = json.dumps(schema_dict)

    pyarrow_schema = deserialize_schema(schema_json)

    assert pyarrow_schema is not None
    assert len(pyarrow_schema) > 0

    field_names = [field.name for field in pyarrow_schema]
    expected_fields = [f["name"] for f in schema_dict["fields"]]
    assert field_names == expected_fields


def test_tactics_schema_field_types():
    schema = get_schema_json("tactics")
    for field in schema["fields"]:
        field_type = field["type"]
        assert isinstance(field_type, (str, dict))


def test_tactics_schema_nullable_flags():
    schema = get_schema_json("tactics")
    for field in schema["fields"]:
        assert isinstance(field["nullable"], bool)


def test_tactics_schema_consistency():
    schema1 = get_schema_json("tactics")
    schema2 = get_schema_json("tactics")
    assert schema1 == schema2
