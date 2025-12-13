module

public import LeanScout.ExtractWith

open LeanScout

public unsafe def main (args : List String) : IO UInt32 := do
  let [mdl, nm, arg] := args | logger.log .error s!"Expected exactly three arguments (JSON config), got {args.length}" ; return 1
  match Lean.Json.parse arg with
  | .ok arg => match Lean.fromJson? (α := ExtractWith.Config) arg with
    | .ok cfg =>
      try ExtractWith.extractWith mdl.toName nm.toName cfg
      catch e => logError s!"Failed extractor with config {arg}: {e}" ; return (1 : UInt32)
    | .error e => logError s!"Failed to parse extractor config: {e}" ; return 1
  | .error e => logError s!"Failed to parse JSON: {e}" ; return 1
