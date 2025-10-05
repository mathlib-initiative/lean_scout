module

public meta import Lean

open Lean

public section

namespace Arrow

mutual

inductive DataType where
  | bool : DataType
  | nat : DataType
  | int : DataType
  | string : DataType
  | float : DataType
  | list : DataType → DataType
  | struct : List Field → DataType

structure Field where
  name : String
  type : DataType
  nullable : Bool := true

end

/-- Arrow schema -/
structure Schema where
  fields : List Field

/-- Convert DataType to JSON -/
meta def DataType.toJson : DataType → Lean.Json
  | .bool => Lean.Json.mkObj [("name", "bool")]
  | .nat => Lean.Json.mkObj [("name", "uint64")]
  | .int => Lean.Json.mkObj [("name", "int64")]
  | .string => Lean.Json.mkObj [("name", "string")]
  | .float => Lean.Json.mkObj [("name", "float64")]
  | .list _ => Lean.Json.mkObj [("name", "list")]
  | .struct _ => Lean.Json.mkObj [("name", "struct")]

/-- Convert Field to JSON -/
meta partial def Field.toJson (f : Field) : Lean.Json :=
  let baseObj := [
    ("name", .str f.name),
    ("nullable", .bool f.nullable),
    ("type", f.type.toJson)
  ]
  -- Add children for nested types
  let withChildren : List (String × Json) := match f.type with
    | .list itemType => baseObj ++ [(
        "children",
        .arr #[Field.toJson { name := "item", type := itemType, nullable := true }]
      )]
    | .struct fields => baseObj ++ [(
        "children",
        .arr (fields.map Field.toJson |>.toArray)
      )]
    | _ => baseObj
  Lean.Json.mkObj withChildren

/-- Convert Schema to JSON -/
meta def Schema.toJson (s : Schema) : Lean.Json :=
  Lean.Json.mkObj [("fields", Lean.Json.arr (s.fields.map Field.toJson |>.toArray))]

class ToDataType (α : Type) where
  dataType : DataType

def dataTypeOf (α : Type) [ToDataType α] : DataType :=
  ToDataType.dataType (α := α)

instance : ToDataType Bool where
  dataType := .bool

instance : ToDataType Int where
  dataType := .int

instance : ToDataType Nat where
  dataType := .nat

instance : ToDataType String where
  dataType := .string

instance : ToDataType Float where
  dataType := .float

instance [ToDataType α] : ToDataType (List α) where
  dataType := .list <| dataTypeOf α

instance [ToDataType α] : ToDataType (Array α) where
  dataType := .list <| dataTypeOf α

end Arrow
