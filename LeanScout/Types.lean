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

/-- Placeholder for writer type -/
structure Writer where
  sink : Json → IO Unit

/--
A `DataExtractor` bundles together the following data:
1. The schema `schema : Schema` of the data being generated.
2. A `key : String`, which should correspond to a field name in `schema`.
  This is used by the Python orchestrator for computing the shard id for each datapoint.
3. A function `go : (Json → IO Unit) -> Target -> IO Unit` which handles the data extraction.

The `go sink tgt` function writes extracted data by calling `sink` with JSON objects.
Each call to `sink j` writes a JSON line to stdout, which is consumed by the Python
orchestrator and written to sharded Parquet files.

In order to activate a data extractor, it must be tagged with the `data_extractor`
attribute. The syntax for this is:
```
@[data_extractor cmd]
def d : DataExtractor := ...
```
Assuming `d` is imported in `Main.lean`, it will then be possible to
use the CLI to call this data extractor with the command `cmd`.

Architecture:
  Lean extracts data and outputs JSON lines to stdout.
  Python orchestrator spawns Lean subprocess(es), reads JSON from stdout,
  and writes to a shared pool of Parquet writers for efficient parallel extraction.

See `LeanScout.DataExtractors.types` for an example.
-/
structure DataExtractor where
  schema : Schema
  key : String
  go : Writer → Target → IO Unit

end LeanScout
