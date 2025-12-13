module

public import LeanScout.DataExtractors
public import LeanScout.Logger

namespace LeanScout

open Lean

namespace Extractor

public unsafe
def extract (cmd : Command) (tgt : Target) (cfg : Json) : IO UInt32 := do
  let some extractor := (data_extractors).get? cmd
    | logger.log .error s!"Failed to find extractor {cmd}" ; return 1
  let stdout ← IO.getStdout
  let sink (j : Json) : IO Unit := do
    stdout.putStrLn j.compress
    stdout.flush
  extractor.go cfg sink {} tgt
  return 0

end Extractor

end LeanScout
