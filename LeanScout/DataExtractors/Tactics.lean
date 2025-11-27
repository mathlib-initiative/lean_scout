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
    { name := "goals", nullable := false, type := .list <| .struct [
      { name := "pp", nullable := false, type := .string },
      { name := "usedConstants", nullable := false, type := .list .string }
    ]},
    { name := "ppTac", nullable := false, type := .string },
    { name := "elaborator", nullable := false, type := .string },
    { name := "kind", nullable := false, type := .string },
  ]
  key := "ppTac"
  go sink
  | .input tgt => discard <| tgt.withVisitM (α := Unit) (ctx? := none)
    (fun _ _ _ => return true) fun ctxInfo info _ _ => ctxInfo.runMetaM' {} do
      let .ofTacticInfo info := info | return
      let some (.original ..) := info.stx.getHeadInfo? | return
      if tacFilter.contains info.stx.getKind then return
      let ppTac : String := toString info.stx.prettyPrint
      let elaborator := info.elaborator
      let kind := toString info.stx.getKind
      let goals : List Json ← info.goalsBefore.mapM fun mvarId =>
        mvarId.withContext do
          let goal ← Lean.Meta.ppGoal mvarId
          let t ← Lean.instantiateMVars <| .mvar mvarId
          let consts := t.getUsedConstantsAsSet
          return json% {
            pp : $(toString goal),
            usedConstants : $(consts.toList.map fun nm => s!"{nm}")
          }
      sink <| json% {
        goals : $(goals),
        ppTac : $(ppTac),
        elaborator : $(elaborator),
        kind : $(kind)
      }
  | _ => throw <| .userError "Unsupported Target"

end DataExtractors
end LeanScout
