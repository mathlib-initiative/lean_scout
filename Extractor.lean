module

public import LeanScout

public unsafe def main (args : List String) : IO UInt32 := do
  let [arg] := args | LeanScout.logger.log .error s!"" ; return 1
  match Lean.Json.parse arg with
  | .ok arg => match Lean.fromJson? (α := LeanScout.Extractor.Config) arg with
    | .ok cfg => LeanScout.Extractor.extract cfg
    | .error e => LeanScout.logger.log .error s!"Failed to parse extractor config: {e}" ; return 1
  | .error e => LeanScout.logger.log .error s!"Failed to parse JSON: {e}" ; return 1
