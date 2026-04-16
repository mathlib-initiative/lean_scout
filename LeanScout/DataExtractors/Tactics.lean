module
public import LeanScout.DataExtractors.Utils
public import LeanScout.Frontend
public import LeanScout.InfoTree
public import LeanScout.Init

open Lean

namespace LeanScout
namespace DataExtractors

private def positionType : DataType :=
  .struct [
    { name := "line", nullable := false, type := .nat },
    { name := "column", nullable := false, type := .nat }
  ]

private def getModuleName? (ctxInfo : Lean.Elab.ContextInfo) : Option String :=
  let moduleName := ctxInfo.env.header.mainModule
  if moduleName == .anonymous then none else some s!"{moduleName}"

private def getSyntaxRange (ctxInfo : Lean.Elab.ContextInfo) (stx : Syntax) : IO (Lean.Position × Lean.Position) := do
  let some startPos := stx.getPos?
    | throw <| IO.userError s!"Original tactic syntax missing start position for '{stx.getKind}'"
  let some endPos := stx.getTailPos?
    | throw <| IO.userError s!"Original tactic syntax missing end position for '{stx.getKind}'"
  return (ctxInfo.fileMap.toPosition startPos, ctxInfo.fileMap.toPosition endPos)

@[data_extractor tactics]
public unsafe def tactics : DataExtractor where
  schema := .mk [
    { name := "module", type := .string },
    { name := "startPos", nullable := false, type := positionType },
    { name := "endPos", nullable := false, type := positionType },
    { name := "goals", nullable := false, type := .list <| .struct [
      { name := "pp", nullable := false, type := .string },
      { name := "usedConstants", nullable := false, type := .list .string }
    ]},
    { name := "ppTac", nullable := false, type := .string },
    { name := "elaborator", nullable := false, type := .string },
    { name := "kind", nullable := false, type := .string },
  ]
  key := "ppTac"
  go config sink opts tgt := do
    match parseEmptyConfig "tactics" config with
    | .ok () => pure ()
    | .error err => throw <| IO.userError err
    discard <| tgt.withVisitM opts (α := Unit) (ctx? := none)
      (fun _ _ _ => return true) fun ctxInfo info _ _ => do
        let .ofTacticInfo info := info | return
        let some (.original ..) := info.stx.getHeadInfo? | return
        let kind := info.stx.getKind
        let ppTac : String := toString info.stx.prettyPrint
        let elaborator := info.elaborator
        let moduleName? := getModuleName? ctxInfo
        let (startPos, endPos) ← getSyntaxRange ctxInfo info.stx
        -- `goalsBefore` must be pretty-printed using `mctxBefore`, but the corresponding
        -- metavariables may only be instantiable using assignments from `mctxAfter`.
        let ctxBefore : Lean.Elab.ContextInfo := { ctxInfo with mctx := info.mctxBefore }
        let ctxAfter : Lean.Elab.ContextInfo := { ctxInfo with mctx := info.mctxAfter }
        let goals : List Json ← info.goalsBefore.mapM fun mvarId => do
          let mvarDecl := info.mctxBefore.getDecl mvarId
          let goal ← ctxBefore.runMetaM' {} do
            Lean.Meta.withLCtx mvarDecl.lctx mvarDecl.localInstances do
              Lean.Meta.ppGoal mvarId
          let consts ← ctxAfter.runMetaM' {} do
            Lean.Meta.withLCtx mvarDecl.lctx mvarDecl.localInstances do
              let t ← Lean.instantiateMVars <| .mvar mvarId
              return t.getUsedConstantsAsSet
          return json% {
            pp : $(toString goal),
            usedConstants : $(consts.toList.map fun nm => s!"{nm}")
          }
        sink <| json% {
          module : $(moduleName?),
          startPos : $(startPos),
          endPos : $(endPos),
          goals : $(goals),
          ppTac : $(ppTac),
          elaborator : $(elaborator),
          kind : $(kind)
        }

end DataExtractors
end LeanScout
