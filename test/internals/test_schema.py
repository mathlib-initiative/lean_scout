"""Tests for the --schema flag on the Lean executable."""
import subprocess
import json
from lean_scout.utils import deserialize_schema


def get_schema_json(command: str) -> dict:
    result = subprocess.run(
        ["lake", "exe", "lean_scout", "--command", command, "--schema"],
        capture_output=True,
        text=True,
        check=True,
    )

    schema_json = result.stdout.strip()
    if not schema_json:
        raise RuntimeError(f"No schema output for command '{command}'")

    return json.loads(schema_json)


def test_schema_types():
    schema = get_schema_json("types")

    assert "fields" in schema
    assert "key" in schema

    assert isinstance(schema["fields"], list)
    assert len(schema["fields"]) > 0

    assert isinstance(schema["key"], str)
    assert schema["key"] == "name"

    for field in schema["fields"]:
        assert "name" in field
        assert "type" in field
        assert "nullable" in field

    field_names = [f["name"] for f in schema["fields"]]
    assert "name" in field_names
    assert "module" in field_names
    assert "type" in field_names


def test_schema_tactics():
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


def test_schema_deserialization_types():
    schema_dict = get_schema_json("types")
    schema_json = json.dumps(schema_dict)

    pyarrow_schema = deserialize_schema(schema_json)

    assert pyarrow_schema is not None
    assert len(pyarrow_schema) > 0

    field_names = [field.name for field in pyarrow_schema]
    expected_fields = [f["name"] for f in schema_dict["fields"]]
    assert field_names == expected_fields


def test_schema_deserialization_tactics():
    schema_dict = get_schema_json("tactics")
    schema_json = json.dumps(schema_dict)

    pyarrow_schema = deserialize_schema(schema_json)

    assert pyarrow_schema is not None
    assert len(pyarrow_schema) > 0

    field_names = [field.name for field in pyarrow_schema]
    expected_fields = [f["name"] for f in schema_dict["fields"]]
    assert field_names == expected_fields


def test_schema_invalid_command():
    result = subprocess.run(
        ["lake", "exe", "lean_scout", "--command", "nonexistent", "--schema"],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0

    stderr_output = result.stderr.lower()
    assert "unknown" in stderr_output or "error" in stderr_output


def test_schema_field_types():
    types_schema = get_schema_json("types")
    for field in types_schema["fields"]:
        field_type = field["type"]
        assert isinstance(field_type, (str, dict))

    tactics_schema = get_schema_json("tactics")
    for field in tactics_schema["fields"]:
        field_type = field["type"]
        assert isinstance(field_type, (str, dict))


def test_schema_nullable_flags():
    types_schema = get_schema_json("types")
    for field in types_schema["fields"]:
        assert isinstance(field["nullable"], bool)

    tactics_schema = get_schema_json("tactics")
    for field in tactics_schema["fields"]:
        assert isinstance(field["nullable"], bool)


def test_schema_consistency():
    schema1 = get_schema_json("types")
    schema2 = get_schema_json("types")
    assert schema1 == schema2

    schema1 = get_schema_json("tactics")
    schema2 = get_schema_json("tactics")
    assert schema1 == schema2
