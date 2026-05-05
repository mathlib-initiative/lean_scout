module
public import LeanScout.DataExtractors.Utils
public import LeanScout.Frontend
public import LeanScout.InfoTree
public import LeanScout.Init

open Lean Meta

namespace LeanScout.DataExtractors

private def positionType : DataType :=
  .struct [
    { name := "line", nullable := false, type := .nat },
    { name := "column", nullable := false, type := .nat }
  ]

/--
Like `Meta.collectMVars`, but also collects used constants after following delayed assignments.
-/
private partial def collectMVarsAndUsedConstants (e : Expr) (consts : NameSet) :
    StateRefT CollectMVars.State MetaM NameSet := do
  let e ← instantiateMVars e
  let s ← get
  let resultSavedSize := s.result.size
  let mut consts := e.getUsedConstantsAsSet ∪ consts
  let s := e.collectMVars s
  set s
  for mvarId in s.result[resultSavedSize...*] do
    match (← getDelayedMVarAssignment? mvarId) with
    | none   => pure ()
    | some d => consts ← collectMVarsAndUsedConstants (.mvar d.mvarIdPending) consts
  return consts

/-- Gets the unassigned metavariables in `e` after following delayed assignments, as well as the
constants encountered along the way. -/
def getMVarsAndConstantsNoDelayed (e : Expr) : MetaM (Array MVarId × NameSet) := do
  let (consts, { result .. }) ← collectMVarsAndUsedConstants e {} |>.run {}
  let result ← result.filterM (notM ·.isDelayedAssigned)
  return (result, consts)

private def getModuleName? (ctxInfo : Lean.Elab.ContextInfo) : Option String :=
  let moduleName := ctxInfo.env.header.mainModule
  if moduleName == .anonymous then none else some s!"{moduleName}"

private structure PositionRangeWithNext where
  startPos : Position
  endPos : Position
  /-- Computed by looking at where the trailing whitespace ends. Does not imply that there is a
  next tactic; this is merely the start position of whatever syntax comes next (possibly a command, tactic combinator, or even the end of the file). -/
  nextStartPos : Position

private def getSyntaxRange (ctxInfo : Lean.Elab.ContextInfo) (stx : Syntax) :
    IO PositionRangeWithNext := do
  let some startPos := stx.getPos?
    | throw <| IO.userError s!"Original tactic syntax missing start position for '{stx.getKind}'"
  let some endPos := stx.getTailPos?
    | throw <| IO.userError s!"Original tactic syntax missing end position for '{stx.getKind}'"
  let some nextStartPos := stx.getTrailingTailPos?
    | throw <| IO.userError s!"Original tactic syntax missing end position after trailing \
      whitespace for '{stx.getKind}'"
  return {
    startPos := ctxInfo.fileMap.toPosition startPos,
    endPos := ctxInfo.fileMap.toPosition endPos,
    nextStartPos := ctxInfo.fileMap.toPosition nextStartPos
  }

local instance : ToString MetavarKind where
  toString
    | .natural => "natural"
    | .synthetic => "synthetic"
    | .syntheticOpaque => "syntheticOpaque"

@[data_extractor tactics]
public unsafe def tactics : DataExtractor where
  schema := .mk [
    { name := "module", type := .string },
    { name := "startPos", nullable := false, type := positionType },
    { name := "endPos", nullable := false, type := positionType },
    { name := "nextStartPos", nullable := false, type := positionType },
    { name := "goals", nullable := false, type := .list <| .struct [
      { name := "pp", nullable := false, type := .string },
      { name := "assigned", nullable := false, type := .bool },
      { name := "usedConstants", nullable := false, type := .list .string },
      { name := "usedFVars", nullable := false, type := .list .string },
      { name := "usedGoals", nullable := false, type := .list <| .struct [
        { name := "new", nullable := false, type := .bool },
        { name := "index", nullable := true, type := .nat }, -- null ↔ does not appear in goal list
        { name := "kind", nullable := false, type := .string },
        { name := "pp", nullable := false, type := .string }
      ]}
    ]},
    { name := "goalsAfter", nullable := false, type := .list .string },
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
        let { startPos, endPos, nextStartPos } ← getSyntaxRange ctxInfo info.stx
        -- `goalsBefore` must be pretty-printed using `mctxBefore`, but the corresponding
        -- metavariables may only be instantiable using assignments from `mctxAfter`.
        let ctxBefore : Elab.ContextInfo := { ctxInfo with mctx := info.mctxBefore }
        let ctxAfter : Elab.ContextInfo := { ctxInfo with mctx := info.mctxAfter }
        let goals : List Json ← info.goalsBefore.mapM fun mvarId => do
          let pp ← ctxBefore.runMetaM' {} do Meta.ppGoal mvarId
          let mvarDeclBefore := info.mctxBefore.getDecl mvarId
          let (assigned, consts, fvars, usedGoals) ← ctxAfter.runMetaM' {} do
            -- Use earlier context in case there was in-place modification of the local context
            withLCtx mvarDeclBefore.lctx mvarDeclBefore.localInstances do
              -- sufficient; user-facing goals will not be delayed-assigned
              let assigned ← mvarId.isAssigned
              let t ← instantiateMVars <| .mvar mvarId
              let (_, { fvarIds .. }) ← t.collectFVars.run {}
              -- Sanitize the names so their string representations are the same as in `ppGoal`.
              let fvars ← if fvarIds.isEmpty then pure #[] else
                let sanitizedLCtx := (← getLCtx).sanitizeNames.run' { options := (← getOptions) }
                withLCtx' sanitizedLCtx do fvarIds.mapM fun fvarId =>
                  return toString (← fvarId.getUserName)
              let (usedGoals, consts) ← if !assigned then pure (#[], {}) else
                let (mvars, consts) ← getMVarsAndConstantsNoDelayed t
                let usedGoals ← mvars.mapM fun mvarId => do
                  let new := !info.mctxBefore.decls.contains mvarId
                  let index? := info.goalsAfter.idxOf? mvarId
                  let kind ← mvarId.getKind
                  let pp ← Meta.ppGoal mvarId
                  return json% {
                    new : $new,
                    index : $index?,
                    kind : $(toString kind),
                    pp : $(toString pp)
                  }
                pure (usedGoals, consts)
              return (assigned, consts, fvars, usedGoals)
          return json% {
            pp : $(toString pp),
            assigned : $assigned,
            usedConstants : $(consts.toList.map fun nm => s!"{nm}"),
            usedFVars : $fvars,
            usedGoals : $usedGoals
          }
        let goalsAfter : List String ← ctxAfter.runMetaM' {} do
          info.goalsAfter.mapM fun mvarId => return toString (← Meta.ppGoal mvarId)
        sink <| json% {
          module : $moduleName?,
          startPos : $startPos,
          endPos : $endPos,
          nextStartPos : $nextStartPos,
          goals : $goals,
          goalsAfter : $goalsAfter,
          ppTac : $ppTac,
          elaborator : $elaborator,
          kind : $kind
        }

end LeanScout.DataExtractors
