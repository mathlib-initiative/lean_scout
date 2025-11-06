import json
from typing import Optional
import pyarrow as pa

def datatype_from_json(type_obj: dict):
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

def field_from_json(field_obj: dict):
    name = field_obj.get("name")
    nullable = field_obj.get("nullable", True)
    type_obj = field_obj.get("type", {})
    datatype = datatype_from_json(type_obj)
    return pa.field(name, datatype, nullable=nullable)

def schema_from_json(schema_obj: dict):
    fields = [field_from_json(field) for field in schema_obj.get("fields", [])]
    return pa.schema(fields)

def deserialize_schema(json_str: str):
    schema_obj = json.loads(json_str)
    return schema_from_json(schema_obj)

def load_schema(schema_str: Optional[str] = None, schema_file: Optional[str] = None) -> pa.Schema:
    """Load PyArrow schema from pandas-compatible JSON string or file."""
    schema_json = None
    if schema_str:
        schema_json = schema_str
    elif schema_file:
        with open(schema_file, 'r') as f:
            schema_json = f.read()
    else:
        raise ValueError("Either --schema or --schema-file must be provided")

    return deserialize_schema(schema_json)
