"""Tests for the --schema flag on the Lean executable."""
import subprocess
import json
from lean_scout.utils import deserialize_schema


def get_schema_json(command: str) -> dict:
    """
    Query Lean for the schema of a given extractor command.

    Args:
        command: Extractor command (e.g., "types", "tactics")

    Returns:
        Parsed schema JSON as dict

    Raises:
        subprocess.CalledProcessError: If schema query fails
    """
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
    """Test schema query for types extractor."""
    schema = get_schema_json("types")

    # Verify JSON structure
    assert "fields" in schema, "Schema should have 'fields' key"
    assert "key" in schema, "Schema should have 'key' key"

    # Verify fields is an array
    assert isinstance(schema["fields"], list), "fields should be a list"
    assert len(schema["fields"]) > 0, "fields should not be empty"

    # Verify key is a string
    assert isinstance(schema["key"], str), "key should be a string"
    assert schema["key"] == "name", "types extractor should use 'name' as key"

    # Verify each field has required properties
    for field in schema["fields"]:
        assert "name" in field, "Field should have 'name' property"
        assert "type" in field, "Field should have 'type' property"
        assert "nullable" in field, "Field should have 'nullable' property"

    # Verify specific expected fields for types extractor
    field_names = [f["name"] for f in schema["fields"]]
    assert "name" in field_names, "types schema should have 'name' field"
    assert "module" in field_names, "types schema should have 'module' field"
    assert "type" in field_names, "types schema should have 'type' field"


def test_schema_tactics():
    """Test schema query for tactics extractor."""
    schema = get_schema_json("tactics")

    # Verify JSON structure
    assert "fields" in schema, "Schema should have 'fields' key"
    assert "key" in schema, "Schema should have 'key' key"

    # Verify fields is an array
    assert isinstance(schema["fields"], list), "fields should be a list"
    assert len(schema["fields"]) > 0, "fields should not be empty"

    # Verify key is a string
    assert isinstance(schema["key"], str), "key should be a string"

    # Verify each field has required properties
    for field in schema["fields"]:
        assert "name" in field, "Field should have 'name' property"
        assert "type" in field, "Field should have 'type' property"
        assert "nullable" in field, "Field should have 'nullable' property"

    # Verify specific expected fields for tactics extractor
    field_names = [f["name"] for f in schema["fields"]]
    assert "ppTac" in field_names, "tactics schema should have 'ppTac' field"


def test_schema_deserialization_types():
    """Test that types schema can be deserialized to PyArrow schema."""
    schema_dict = get_schema_json("types")

    # Reconstruct the full schema JSON as a single line (as Lean outputs it)
    schema_json = json.dumps(schema_dict)

    # This should not raise an exception
    pyarrow_schema = deserialize_schema(schema_json)

    # Verify we got a valid schema
    assert pyarrow_schema is not None
    assert len(pyarrow_schema) > 0, "Schema should have fields"

    # Verify field names match
    field_names = [field.name for field in pyarrow_schema]
    expected_fields = [f["name"] for f in schema_dict["fields"]]
    assert field_names == expected_fields, "PyArrow schema fields should match JSON schema"


def test_schema_deserialization_tactics():
    """Test that tactics schema can be deserialized to PyArrow schema."""
    schema_dict = get_schema_json("tactics")

    # Reconstruct the full schema JSON as a single line (as Lean outputs it)
    schema_json = json.dumps(schema_dict)

    # This should not raise an exception
    pyarrow_schema = deserialize_schema(schema_json)

    # Verify we got a valid schema
    assert pyarrow_schema is not None
    assert len(pyarrow_schema) > 0, "Schema should have fields"

    # Verify field names match
    field_names = [field.name for field in pyarrow_schema]
    expected_fields = [f["name"] for f in schema_dict["fields"]]
    assert field_names == expected_fields, "PyArrow schema fields should match JSON schema"


def test_schema_invalid_command():
    """Test that invalid extractor command returns non-zero exit code."""
    result = subprocess.run(
        ["lake", "exe", "lean_scout", "--command", "nonexistent", "--schema"],
        capture_output=True,
        text=True,
    )

    # Should fail with non-zero exit code
    assert result.returncode != 0, "Invalid command should return non-zero exit code"

    # Error message should mention the unknown command
    stderr_output = result.stderr.lower()
    assert "unknown" in stderr_output or "error" in stderr_output, \
        "Error message should indicate unknown command"


def test_schema_field_types():
    """Test that schema fields have valid type specifications."""
    # Test types extractor
    types_schema = get_schema_json("types")
    for field in types_schema["fields"]:
        field_type = field["type"]
        # Type should be a string (simple type) or dict (complex type)
        assert isinstance(field_type, (str, dict)), \
            f"Field type should be string or dict, got {type(field_type)}"

    # Test tactics extractor
    tactics_schema = get_schema_json("tactics")
    for field in tactics_schema["fields"]:
        field_type = field["type"]
        assert isinstance(field_type, (str, dict)), \
            f"Field type should be string or dict, got {type(field_type)}"


def test_schema_nullable_flags():
    """Test that all fields have boolean nullable flags."""
    # Test types extractor
    types_schema = get_schema_json("types")
    for field in types_schema["fields"]:
        assert isinstance(field["nullable"], bool), \
            f"Field nullable should be bool, got {type(field['nullable'])}"

    # Test tactics extractor
    tactics_schema = get_schema_json("tactics")
    for field in tactics_schema["fields"]:
        assert isinstance(field["nullable"], bool), \
            f"Field nullable should be bool, got {type(field['nullable'])}"


def test_schema_consistency():
    """Test that querying schema multiple times returns consistent results."""
    # Query types schema twice
    schema1 = get_schema_json("types")
    schema2 = get_schema_json("types")

    # Should be identical
    assert schema1 == schema2, "Schema queries should be consistent"

    # Query tactics schema twice
    schema1 = get_schema_json("tactics")
    schema2 = get_schema_json("tactics")

    # Should be identical
    assert schema1 == schema2, "Schema queries should be consistent"
