module

public import LeanScout.ExtractWith

open LeanScout

public unsafe def main (args : List String) : IO UInt32 := do
  let [mdl, nm, tgtStr, cfgStr] := args | logger.log .error s!"Expected exactly four arguments (JSON config), got {args.length}" ; return 1
  match Lean.Json.parse tgtStr, Lean.Json.parse cfgStr with
  | .ok tgt, .ok cfg =>
    match Lean.fromJson? (α := Target) tgt with
    | .ok tgt =>
      try ExtractWith.extractWith mdl.toName nm.toName tgt cfg
      catch e => logError s!"Failed extractor with target {tgtStr} and config {cfgStr}: {e}" ; return (1 : UInt32)
    | .error e => logError s!"Failed to parse extractor config: {e}" ; return 1
  | .error e, _ => logError s!"Failed to parse JSON: {e}" ; return 1
  | _, .error e => logError s!"Failed to parse JSON: {e}" ; return 1
