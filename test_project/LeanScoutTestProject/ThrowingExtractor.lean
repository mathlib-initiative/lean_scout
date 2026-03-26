import LeanScout

open Lean
open LeanScout

namespace LeanScoutTestProject

@[data_extractor throwing_imports]
unsafe def throwingImports : DataExtractor where
  schema := .mk [
    { name := "name", nullable := false, type := .string }
  ]
  key := "name"
  go _ sink opts
  | .imports tgt => do
    let failedRef ← IO.mkRef false
    tgt.runParallelCoreM opts (maxTasks := some 1) fun _ n _ => do
      if !(← failedRef.get) then
        failedRef.set true
        let _ ← (throw <| IO.userError "intentional per-constant worker failure" : IO Unit)
        return
      sink <| json% {
        name : $(n)
      }
  | _ => throw <| IO.userError "Unsupported Target"

end LeanScoutTestProject
