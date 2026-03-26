module
public import Lean

open Lean

public section

namespace LeanScout
namespace DataExtractors

abbrev ConfigObj := Std.TreeMap.Raw String Json compare

structure TaskLimitConfig where
  taskLimit : Option Nat := none

private def getConfigObj (extractorName : String) (config : Json) : Except String ConfigObj :=
  config.getObj? |>.mapError fun err => s!"Invalid config for extractor '{extractorName}': {err}"

private def rejectUnknownKeys
    (extractorName : String) (obj : ConfigObj) (allowed : List String) : Except String Unit := do
  obj.foldlM (init := ()) fun _ key _ => do
    if allowed.contains key then
      pure ()
    else
      throw s!"Invalid config for extractor '{extractorName}': unknown field '{key}'"

private def getOptionalField [FromJson α]
    (extractorName : String) (obj : ConfigObj) (field : String) : Except String (Option α) := do
  match obj[field]? with
  | none =>
      pure none
  | some value =>
      match fromJson? value with
      | .ok parsed =>
          pure (some parsed)
      | .error err =>
          throw s!"Invalid config for extractor '{extractorName}', field '{field}': {err}"

public def parseEmptyConfig (extractorName : String) (config : Json) : Except String Unit := do
  let obj ← getConfigObj extractorName config
  rejectUnknownKeys extractorName obj []

public def parseTaskLimitConfig
    (extractorName : String) (config : Json) : Except String TaskLimitConfig := do
  let obj ← getConfigObj extractorName config
  rejectUnknownKeys extractorName obj ["taskLimit"]
  return {
    taskLimit := ← getOptionalField extractorName obj "taskLimit"
  }

end DataExtractors
end LeanScout
