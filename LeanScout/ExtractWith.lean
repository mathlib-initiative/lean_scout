module

public import LeanScout.Frontend
public import LeanScout.Logger

namespace LeanScout

open Lean

namespace ExtractWith

public unsafe
def getDataExtractor (mdl nm : Name) : IO DataExtractor := do
  let importTgt : ImportsTarget := .mk <| #[{ module := mdl }]
  importTgt.runCoreM {} <| Meta.MetaM.run' do
    let some c := (← getEnv).find? nm
      | show IO _ from throw <| IO.userError s!"Failed to find {nm}"
    let .const ``DataExtractor [] := c.type
      | show IO _ from throw <| .userError s!"{nm} is not a data extractor."
    Meta.evalExpr DataExtractor (.const ``DataExtractor []) (.const nm [])

public unsafe
def extractWith (mdl nm : Name) (tgt : Target) (cfg : Json): IO UInt32 := do
  try
    let stdout ← IO.getStdout
    let sink (j : Json) : IO Unit := do
      stdout.putStrLn j.compress
      stdout.flush
    let d ← getDataExtractor mdl nm
    d.go cfg sink {} tgt
    return 0
  catch e =>
    logError s!"{e}"
    return 1

end ExtractWith

end LeanScout
