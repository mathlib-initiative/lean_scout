module

public import Lean

public section

namespace LeanScout

mutual

inductive DataType where
  | bool : DataType
  | nat : DataType
  | int : DataType
  | string : DataType
  | float : DataType
  | list : DataType → DataType
  | struct : List Field → DataType
deriving BEq

structure Field where
  name : String
  type : DataType
  nullable : Bool := true
deriving BEq

end

/-- Arrow schema -/
structure Schema where
  fields : List Field
deriving BEq

open Lean

structure BaseTarget where
  opts : Options

structure ImportsTarget extends BaseTarget where
  imports : Array Import

structure InputTarget extends BaseTarget where
  path : System.FilePath

inductive Target where
  | imports (imports : ImportsTarget)
  | input (input : InputTarget)

/--
A `DataExtractor` bundles together the following data:
1. The schema `schema : Schema` of the data being generated.
2. A `key : String`, which should correspond to a key in `schema`.
  This is used for computing the shard id for the given datapoint.
3. A function `go : (Json → IO Unit) -> Target -> IO Unit` which handles the data extraction.

It is expected that `go sink tgt` will use `sink` to register a datapoint to be saved.

In order to activate a data extractor, it must be tagged with the `data_extractor`
attribute. The syntax for this is
```
@[data_extractor cmd]
def d : DataExtractor := ...
```
Assuming `d` is imported in `Main.lean`, it will then be possible to
use the CLI to call this data extractor with the command `cmd`.

See `LeanScout.DataExtractors.types` for an example.
-/
structure DataExtractor where
  schema : Schema
  key : String
  go : (Json → IO Unit) → Target → IO Unit

end LeanScout
