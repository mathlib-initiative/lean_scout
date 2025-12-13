module

public import LeanScout

open LeanScout

public unsafe def main (args : List String) : IO UInt32 := do
  let [cmd, arg] := args | logger.log .error s!"Expected exactly two arguments (JSON config), got {args.length}" ; return 1
  match Lean.Json.parse arg with
  | .ok arg => match Lean.fromJson? (α := Extractor.Config) arg with
    | .ok cfg =>
      try Extractor.extract cmd.toName cfg
      catch e => logError s!"Failed extractor with config {arg}: {e}" ; return (1 : UInt32)
    | .error e => logError s!"Failed to parse extractor config: {e}" ; return 1
  | .error e => logError s!"Failed to parse JSON: {e}" ; return 1
