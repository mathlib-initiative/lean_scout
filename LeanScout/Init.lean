module

public import LeanScout.Types

open Lean


public meta section

namespace LeanScout

abbrev Command := Name

def reservedCommands : List Command :=
  [ `extractors ]

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
    if reservedCommands.contains cmd then throwError "data extractor {cmd} is a reserved command"
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
