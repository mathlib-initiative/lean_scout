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
