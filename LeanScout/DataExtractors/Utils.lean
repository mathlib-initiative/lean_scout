module
public import Lean

open Lean

public section

namespace LeanScout
namespace DataExtractors

abbrev ConfigObj := Std.TreeMap.Raw String Json compare

structure FilterConfig where
  filter : Bool := false

structure FilterTaskLimitConfig where
  filter : Bool := false
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

public def parseFilterConfig (extractorName : String) (config : Json) : Except String FilterConfig := do
  let obj ← getConfigObj extractorName config
  rejectUnknownKeys extractorName obj ["filter"]
  return {
    filter := (← getOptionalField extractorName obj "filter").getD false
  }

public def parseFilterTaskLimitConfig
    (extractorName : String) (config : Json) : Except String FilterTaskLimitConfig := do
  let obj ← getConfigObj extractorName config
  rejectUnknownKeys extractorName obj ["filter", "taskLimit"]
  return {
    filter := (← getOptionalField extractorName obj "filter").getD false
    taskLimit := ← getOptionalField extractorName obj "taskLimit"
  }

-- A more aggressive variant of Lean's own completion blacklist.
--
-- We start from `Lean.Meta.allowCompletion`, but close the predicate under
-- prefixes so that descendants of filtered declarations are filtered as well
-- (e.g. `Nat.brecOn.eq`, `...match_3.congr_eq_2`). We also keep a small set of
-- project-specific exclusions that Lean does not blacklist for completion.
private def isExtraFilteredLeaf : Name → Bool
  | .str _ s =>
      s == "inj" ||
      s == "injEq" ||
      s == "sizeOf_spec" ||
      s == "toCtorIdx"
  | _ => false

private def hasFilteredNamespace (declName : Name) : Bool :=
  declName.components.contains `Grind || declName.components.contains `Omega

private def anyPrefix (declName : Name) (p : Name → Bool) : Bool :=
  p declName || match declName with
    | .anonymous => false
    | .str pre _ => anyPrefix pre p
    | .num pre _ => anyPrefix pre p

def declNameFilterCore (env : Environment) (declName : Name) : Bool :=
  hasFilteredNamespace declName ||
  anyPrefix declName fun n =>
    n == ``sorryAx ||
    n.isInternalDetail ||
    isPrivateName n ||
    !Lean.Meta.allowCompletion env n ||
    isExtraFilteredLeaf n

def declNameFilter {m} [Monad m] [MonadEnv m] (declName : Name) : m Bool := do
  return declNameFilterCore (← getEnv) declName

def tacFilter : Lean.SyntaxNodeKinds := [
  `Lean.Parser.Term.byTactic,
  `Lean.Parser.Tactic.tacticSeq,
  `Lean.Parser.Tactic.tacticSeq1Indented,
  `Lean.Parser.Tactic.withAnnotateState,
  `Lean.cdotTk,
  `Lean.cdot,
  `ident,
  `«by»,
  `«;»,
  `«<;>»,
  `«{»,
  `«]»,
  Lean.nullKind,
]

end DataExtractors
end LeanScout
