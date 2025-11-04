module

public import LeanScout.Types

open Lean

public section

namespace LeanScout

mutual

partial def DataType.toJson (d : DataType) : Lean.Json := match d with
  | .bool => json% { datatype : "bool" }
  | .nat => json% { datatype : "nat" }
  | .int => json% { datatype : "int" }
  | .string => json% { datatype : "string" }
  | .float => json% { datatype : "float" }
  | .list item => json% { datatype : "list", item : $(DataType.toJson item) }
  | .struct children => json% { datatype : "struct", children : $(children.map Field.toJson |>.toArray) }

partial def Field.toJson (f : Field) : Lean.Json :=
  json% {
    "name" : $(f.name),
    "type" : $(f.type.toJson),
    "nullable" : $(f.nullable)
  }

end

mutual

partial def DataType.fromJson? (j : Json) : Except String DataType := do
  match ← j.getObjValAs? String "datatype" with
  | "bool" => return .bool
  | "nat" => return .nat
  | "int" => return .int
  | "string" => return .string
  | "float" => return .float
  | "list" =>
    let item ← j.getObjVal? "item"
    return .list <| ← DataType.fromJson? item
  | "struct" =>
    let children ← j.getObjValAs? (Array Json) "children"
    return .struct <| (← children.mapM Field.fromJson?).toList
  | t => throw s!"Invalid DataType {t}"

partial def Field.fromJson? (j : Json) : Except String Field := do
  let nm ← j.getObjValAs? String "name"
  let nullable ← j.getObjValAs? Bool "nullable"
  let tp ← DataType.fromJson? (← j.getObjVal? "type")
  return { name := nm, type := tp, nullable := nullable }

end

def Schema.toJson (s : Schema) : Json :=
  json% { fields : $(s.fields.map Field.toJson |>.toArray) }

def Schema.fromJson? (j : Json) : Except String Schema := do
  let fieldsJson ← j.getObjValAs? (Array Json) "fields"
  let fields ← fieldsJson.mapM Field.fromJson?
  return { fields := fields.toList }

instance : ToJson Schema where
  toJson := Schema.toJson

instance : FromJson Schema where
  fromJson? := Schema.fromJson?

end LeanScout
