import sys

from lean_scout import deserialize_schema

if __name__ == "__main__":
    for line in sys.stdin:
        schema = deserialize_schema(line.strip())
        print(schema.to_string(show_field_metadata=True, show_schema_metadata=True))
