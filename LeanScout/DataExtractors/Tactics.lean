module
public import LeanScout.DataExtractors.Utils
public import LeanScout.Frontend
public import LeanScout.InfoTree
public import LeanScout.Init

open Lean

namespace LeanScout
namespace DataExtractors

@[data_extractor tactics]
public unsafe def tactics : DataExtractor where
  schema := .mk [
    { name := "ppGoals", nullable := false, type := .list .string },
    { name := "ppTac", nullable := false, type := .string },
  ]
  key := "ppTac"
  go handle
  | .input tgt => discard <| tgt.withVisitM (α := Unit) (ctx? := none)
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
  | _ => throw <| .userError "Unsupported Target"

end DataExtractors
end LeanScout
