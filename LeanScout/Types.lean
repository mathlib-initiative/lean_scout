module

public import Lean

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

end Arrow

namespace LeanScout

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
1. The schema `schema : Arrow.Schem` of the data being generated.
2. A `key : String`, which should correspond to a key in `schema`.
  This is used for computing the shard id for the given datapoint.
3. A function `go : IO.FS.Hansle -> Target -> IO Unit` which handles the data extraction.

It is expected that `go handle tgt` will write json lines (newline delimited)
to `handle`, whose schema should match the given `schema`.

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
public structure DataExtractor where
  schema : Arrow.Schema
  key : String
  go : IO.FS.Handle → Target → IO Unit

end LeanScout
