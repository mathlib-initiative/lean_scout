module

public import LeanScout.Frontend
public import LeanScout.Logger

namespace LeanScout

open Lean

namespace ExtractWith
public structure Config where
  target : Target
  extractorConfig : Json := Json.mkObj []
deriving ToJson, FromJson

public unsafe
def extractWith (mdl : Name) (nm : Name) (cfg : Config): IO UInt32 := do
  let importTgt : ImportsTarget := .mk <| #[{ module := mdl }]
  importTgt.runCoreM {} <| Meta.MetaM.run' do
    let some c := (← getEnv).find? nm
      | logError s!"Failed to find {nm}" ; return 1
    let .const `DataExtractor [] := c.type
      | logError s!"{nm} is not a data extractor" ; return 1
    let d ← Meta.evalExpr DataExtractor (.const `DataExtractor []) (.const nm [])
    let stdout ← IO.getStdout
    let sink (j : Json) : IO Unit := do
      stdout.putStrLn j.compress
      stdout.flush
    d.go cfg.extractorConfig sink {} cfg.target
    return 0

end ExtractWith

end LeanScout
