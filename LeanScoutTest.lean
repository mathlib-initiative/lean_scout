import LeanScout

open Lean

-- Test the schema ToJson and FromJson functions on schemas of all data extractors
#eval show IO Unit from do
  for (n,e) in data_extractors do
    let j := toJson e.schema
    match fromJson? j with
    | .ok s => unless s == e.schema do
      throw <| .userError n.toString
    | .error e => throw <| .userError e

open LeanScout in
def schemaRoundtrip (schema : Schema) : IO Unit := do
  let c ← IO.Process.spawn {
    cmd := "uv"
    args := #["run", "python", "test/schema.py"]
    stdin := .piped
    stdout := .piped
  }
  let (stdin, _) ← c.takeStdin
  stdin.putStrLn schema.toJson.compress
  println! "\n"
  println! (← c.stdout.readToEnd).trim

/--
info:
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk []

/--
info:

field: bool
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .bool }
]

/--
info:

field: uint64 not null
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", nullable := false, type := .nat }
]

/--
info:

field: int64
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .int }
]

/--
info:

field: double
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .float }
]

/--
info:

field: string
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .string }
]

/--
info:

field: list<item: string>
  child 0, item: string
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .list .string }
]

/--
info:

field: list<item: uint64> not null
  child 0, item: uint64
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", nullable := false, type := .list .nat }
]

/--
info:

field: list<item: bool>
  child 0, item: bool
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .list .bool }
]

/--
info:

field: struct<x: double, y: double>
  child 0, x: double
  child 1, y: double
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .struct [
    { name := "x", type := .float },
    { name := "y", type := .float }
  ]}
]

/--
info:

field: struct<name: string not null, age: int64, active: bool not null> not null
  child 0, name: string not null
  child 1, age: int64
  child 2, active: bool not null
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", nullable := false, type := .struct [
    { name := "name", nullable := false, type := .string },
    { name := "age", type := .int },
    { name := "active", nullable := false, type := .bool }
  ]}
]

/--
info:

field: list<item: struct<id: string not null, value: double>>
  child 0, item: struct<id: string not null, value: double>
      child 0, id: string not null
      child 1, value: double
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .list <| .struct [
    { name := "id", nullable := false, type := .string },
    { name := "value", type := .float }
  ]}
]

/--
info:

field: struct<items: list<item: string>, count: uint64 not null>
  child 0, items: list<item: string>
      child 0, item: string
  child 1, count: uint64 not null
-/
#guard_msgs in
#eval schemaRoundtrip <| .mk [
  { name := "field", type := .struct [
    { name := "items", type := .list .string },
    { name := "count", nullable := false, type := .nat }
  ]}
]
