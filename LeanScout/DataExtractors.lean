module
public meta import LeanScout.InfoTree
public meta import LeanScout.Init

namespace LeanScout

open Lean

meta def tacFilter : Lean.SyntaxNodeKinds := [
  `Lean.Parser.Term.byTactic,
  `Lean.Parser.Tactic.tacticSeq,
  `Lean.Parser.Tactic.tacticSeq1Indented,
  `Lean.Parser.Tactic.withAnnotateState,
  `Lean.cdotTk,
  `«by»,
  `«;»,
  `«]»,
  Lean.nullKind,
]

-- A more agressive Variant of `Lean.Name.isBlackListed`.
-- TODO: We need a more robust way to ignore internal constants.
meta def declNameFilter {m} [Monad m] [MonadEnv m] (declName : Name) : m Bool := do
  if declName == ``sorryAx then return true
  if declName matches .str _ "inj" then return true
  if declName matches .str _ "injEq" then return true
  if declName matches .str _ "rec" then return true
  if declName matches .str _ "recOn" then return true
  if declName matches .str _ "sizeOf_spec" then return true
  if declName matches .str _ "brecOn" then return true
  if declName matches .str _ "recOn" then return true
  if declName matches .str _ "casesOn" then return true
  if declName matches .str _ "toCtorIdx" then return true
  if declName matches .str _ "noConfusionType" then return true
  if declName.components.contains `Grind then return true
  if declName.components.contains `Omega then return true
  if declName.isInternalDetail then return true
  let env ← getEnv
  if isAuxRecursor env declName then return true
  if isNoConfusion env declName then return true
  if ← isRec declName then return true
  if ← Meta.isMatcher declName then return true
  return false

@[data_extractor]
public meta unsafe def types : DataExtractor where
  command := "types"
  go handle tgt := tgt.runCoreM <| Meta.MetaM.run' do
    let env ← getEnv
    for (n, c) in env.constants do
      if ← declNameFilter n then continue
      handle.putStrLn <| Json.compress <| json% {
        name : $(n),
        type : $(s!"{← Meta.ppExpr c.type}")
      }

@[data_extractor]
public meta unsafe def tactics : DataExtractor where
  command := "tactics"
  go handle tgt := discard <| tgt.withVisitM (α := Unit) (ctx? := none)
    (fun _ _ _ => return true) fun ctxInfo info _ _ => ctxInfo.runMetaM' {} do
      let .ofTacticInfo info := info | return
      let some (.original ..) := info.stx.getHeadInfo? | return
      if tacFilter.contains info.stx.getKind then return
      let ppTac : String := toString info.stx.prettyPrint
      let ppGoals : List String ← info.goalsBefore.mapM fun mvarId =>
        mvarId.withContext do
          let goal ← Lean.Meta.ppGoal mvarId
          return toString goal
      handle.putStrLn <| Lean.Json.compress <| json% {
        ppGoals : $(ppGoals),
        ppTac : $(ppTac)
      }

end LeanScout
