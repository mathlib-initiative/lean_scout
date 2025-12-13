module

public import LeanScout.Frontend
public import LeanScout.Logger

namespace LeanScout

open Lean

namespace ExtractWith
public structure Config where
  module : Name
  name : Name
  target : Target
  extractorConfig : Json := Json.mkObj []
deriving ToJson, FromJson

public unsafe
def extractWith (cfg : Config): IO UInt32 := do
  let importTgt : ImportsTarget := .mk <| #[{ module := cfg.module }]
  importTgt.runCoreM {} <| Meta.MetaM.run' do
    let some c := (← getEnv).find? cfg.name
      | logError s!"Failed to find {cfg.name}" ; return 1
    let .const `DataExtractor [] := c.type
      | logError s!"{cfg.name} is not a data extractor" ; return 1
    let d ← Meta.evalExpr DataExtractor (.const `DataExtractor []) (.const cfg.name [])
    let stdout ← IO.getStdout
    let sink (j : Json) : IO Unit := do
      stdout.putStrLn j.compress
      stdout.flush
    d.go cfg.extractorConfig sink {} cfg.target
    return 0

end ExtractWith

end LeanScout
