module

import LeanScout

public unsafe
def main (args : List String) : IO UInt32 := do
  let [cmd] := args | throw <| .userError "expected exactly one argument: <command>"
  let some extractor := (data_extractors).get? cmd.toName
    | throw <| .userError s!"unknown command '{cmd}'"
  println! Lean.toJson extractor.schema
  return 0
