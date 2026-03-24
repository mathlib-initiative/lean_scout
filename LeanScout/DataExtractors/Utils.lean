module
public import Lean

open Lean

public section

namespace LeanScout
namespace DataExtractors

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
