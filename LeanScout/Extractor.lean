module

public import LeanScout.DataExtractors
public import LeanScout.Logger

namespace LeanScout

open Lean

namespace Extractor
public structure Config where
  command : Command
  target : Target
deriving ToJson, FromJson

public unsafe
def extract (cfg : Config): IO UInt32 := do
  let some extractor := (data_extractors).get? cfg.command
    | logger.log .error s!"Failed to find extractor {cfg.command}" ; return 1
  let stdout ← IO.getStdout
  let sink (j : Json) : IO Unit := do
    stdout.putStrLn j.compress
    stdout.flush
  extractor.go sink {} cfg.target
  return 0

end Extractor

end LeanScout
