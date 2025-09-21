module

public import LeanScout.DataExtractor

open Lean

public section

namespace LeanScout

initialize dataExtractorsExt : PersistentEnvExtension Name Name NameSet ←
  registerPersistentEnvExtension {
    mkInitial := return {}
    addImportedFn as := do
      let mut out := {}
      for bs in as do for b in bs do out := out.insert b
      return out
    addEntryFn := .insert
    exportEntriesFnEx _ s _ := s.toArray
  }

syntax (name := dataExtractorAttr) "data_extractor" : attr

initialize registerBuiltinAttribute {
  name := `dataExtractorAttr
  descr := "Register a data extractor"
  add n _ _ := modifyEnv fun e => dataExtractorsExt.addEntry e n
}

open Elab Term in
elab "data_extractors" : term => do
  let extractors := dataExtractorsExt.getState (← getEnv)
  let mut out ← Meta.mkAppOptM ``Array.empty #[some (.const ``DataExtractor [])]
  for extractor in extractors do
    out ← Meta.mkAppOptM ``Array.push #[none, out, some <| .const extractor []]
  return out

end LeanScout
