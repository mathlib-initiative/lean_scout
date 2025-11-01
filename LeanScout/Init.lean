module

public import LeanScout.Frontend
public meta import Lean.Elab.Term
public meta import LeanScout.Schema

open Lean

public section

namespace LeanScout

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
public meta structure DataExtractor where
  schema : Arrow.Schema
  key : String
  go : IO.FS.Handle → Target → IO Unit

abbrev Command := Name

initialize dataExtractorsExt : PersistentEnvExtension (Command × Name) (Command × Name) (Std.HashMap Command Name) ←
  registerPersistentEnvExtension {
    mkInitial := return {}
    addImportedFn as := do
      let mut out := {}
      for bs in as do for (x,y) in bs do out := out.insert x y
      return out
    addEntryFn S := fun (x,y) => S.insert x y
    exportEntriesFnEx _ s _ := s.toArray
  }

syntax (name := dataExtractorAttr) "data_extractor" ident : attr

initialize registerBuiltinAttribute {
  name := `dataExtractorAttr
  descr := "Register a data extractor"
  add n s _ := do
    let `(attr|data_extractor $cmd:ident) := s
      | throwError "data_extractor attribute must be of the form `data_extractor <cmd>`"
    let dataExtractors := dataExtractorsExt.getState (← getEnv)
    let cmd := cmd.getId
    if dataExtractors.contains cmd then
      throwError "data extractor {cmd} is already registered"
    modifyEnv fun e => dataExtractorsExt.addEntry e (cmd,n)
}

open Elab Term in
elab "data_extractors" : term => do
  let extractors := dataExtractorsExt.getState (← getEnv)
  let mut out ← Meta.mkAppOptM ``Std.HashMap.empty
    #[some (.const ``Command []), some (.const ``DataExtractor []), none, none, some (toExpr 8)]
  for (cmd,extractor) in extractors do
    out ← Meta.mkAppOptM ``Std.HashMap.insert
      #[none, none, none, none, out, some <| toExpr cmd, some <| .const extractor []]
  return out

end LeanScout
