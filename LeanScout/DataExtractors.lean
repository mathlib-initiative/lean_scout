module
public meta import LeanScout.InfoTree
public meta import LeanScout.Init
public meta import LeanScout.Schema

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

@[data_extractor types]
public meta unsafe def types : DataExtractor where
  schema := .mk [
    { name := "name", nullable := false, type := .string },
    { name := "type", nullable := false, type := .string },
  ]
  key := "name"
  go handle
  | .imports tgt => tgt.runCoreM <| Meta.MetaM.run' do
    let env ← getEnv
    for (n, c) in env.constants do
      if ← declNameFilter n then continue
      handle.putStrLn <| Json.compress <| json% {
        name : $(n),
        type : $(s!"{← Meta.ppExpr c.type}")
      }
  | _ => throw <| .userError "Unsupported Target"

@[data_extractor tactics]
public meta unsafe def tactics : DataExtractor where
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

section Subterms

structure FVarGraph where
  depGraph : Std.HashMap FVarId (Std.HashSet FVarId)
  exprDeps : Std.HashSet FVarId

meta def FVarGraph.toJson (idx : Std.HashMap FVarId Nat) (G : FVarGraph) : Json := json%{
  expr : $(G.exprDeps.toArray.map fun fvarId => idx.get? fvarId),
  fvar : $(G.depGraph.toArray.map fun (fvarId, deps) => json% {
    var : $(idx.get? fvarId),
    deps : $(deps.toArray.map fun fvarId => idx.get? fvarId)
  })
}

meta def FVarGraph.dataType : Arrow.DataType := .struct [
  { name := "expr", nullable := false, type := Arrow.dataTypeOf (Array Nat) },
  { name := "fvar", nullable := false, type := .list <| .struct [
    { name := "var", nullable := false, type := Arrow.dataTypeOf Nat },
    { name := "deps", nullable := false, type := Arrow.dataTypeOf (Array Nat) },
  ]}
]

meta def computeFVarGraph (e : Expr) : MetaM FVarGraph := do
  let mut exprDeps : Std.HashSet FVarId := {}
  let mut depGraph : Std.HashMap FVarId (Std.HashSet FVarId) := {}
  for decl in ← getLCtx do
    let f := decl.fvarId
    if e.containsFVar decl.fvarId then exprDeps := exprDeps.insert f
    for decl' in ← getLCtx do
      let g := decl'.fvarId
      if decl.type.containsFVar g then
        depGraph := depGraph.insert f <| (depGraph.getD f {}).insert g
  return ⟨depGraph, exprDeps⟩

private meta def exprWithLCtx (e : Expr) : MetaM Json := do
  let lctx := (← getLCtx).sanitizeNames.run' { options := (← getOptions) } |>.run
  Meta.withLCtx lctx (← Meta.getLocalInstances) do
    let mut varFmts : Array (Name × Format × Option Format × Bool × Bool × Nat) := #[]
    let mut idx : Std.HashMap FVarId Nat := {}
    let typeFmt ← Meta.ppExpr e
    for decl in lctx do
      match decl with
      | .cdecl _ _ nm tp _ .. =>
        varFmts := varFmts.push (nm, ← Meta.ppExpr tp, none, decl.isAuxDecl, decl.isImplementationDetail, idx.size)
      | .ldecl _ _ nm tp val .. =>
        varFmts := varFmts.push (nm, ← Meta.ppExpr tp, ← Meta.ppExpr val, decl.isAuxDecl, decl.isImplementationDetail, idx.size)
      idx := idx.insert decl.fvarId idx.size
    let lctx : Array Json := varFmts.map fun (nm, tp, val?, isAux, isImpl, idx) => json%{
      name : $(nm),
      type : $(tp.pretty),
      value : $(val?.map fun fmt => fmt.pretty),
      isAuxDetail : $(isAux),
      isImplDetail : $(isImpl),
      idx : $(idx)
    }
    let fvarGraph ← computeFVarGraph e
    return json%{
        expr : $(typeFmt.pretty),
        lctx : $(lctx),
        fvarGraph : $(fvarGraph.toJson idx)
      }

meta def lCtxDatatype : Arrow.DataType := .struct [
  { name := "name", nullable := false, type := .string },
  { name := "type", nullable := false, type := .string },
  { name := "value", nullable := true, type := .string },
  { name := "isAuxDetail", nullable := false, type := .bool },
  { name := "isImplDetail", nullable := false, type := .bool },
  { name := "idx", nullable := false, type := .nat },
]

meta def exprWithLCtxDatatype : Arrow.DataType := .struct [
  { name := "expr", nullable := false, type := .string },
  { name := "lctx", nullable := false, type := .list lCtxDatatype },
  { name := "fvarGraph", nullable := false, type := FVarGraph.dataType }
]

private meta def writeSubtermsWithTypes
    (writer : Std.Mutex IO.FS.Handle)
    (kind : String)
    (parent : Name)
    (e : Expr) : MetaM Unit := do
  Meta.forEachExpr e fun e => do
    let datapoint ← exprWithLCtx e
    let datapointType ← exprWithLCtx <| ← Meta.inferType e
    writer.atomically do
      let h ← get
      h.putStrLn <| Json.compress <| json% {
        kind : $(kind),
        parent : $(parent),
        expr : $(datapoint),
        type : $(datapointType)
      }
      h.flush

meta def subtermWithTypesSchema : Arrow.Schema := .mk [
  { name := "kind", nullable := false, type := .string },
  { name := "parent", nullable := false, type := .string },
  { name := "expr", nullable := false, type := exprWithLCtxDatatype },
  { name := "type", nullable := false, type := exprWithLCtxDatatype }
]

@[data_extractor subtermsWithTypes]
public meta unsafe def subtermsWithTypes : DataExtractor where
  key := "parent"
  schema := subtermWithTypesSchema
  go handle
  | .imports tgt => do
    let handle ← Std.Mutex.new handle
    discard <| { tgt with opts := maxHeartbeats.set tgt.opts 0 }.runParallelCoreM  (α := Unit)
      fun _ n c => Meta.MetaM.run' do
        if ← declNameFilter n then return
        writeSubtermsWithTypes handle "type" n c.type
        if let some val := c.value? then
          writeSubtermsWithTypes handle "val" n val
  | _ => throw <| .userError "Unsupported Target"

end Subterms

end LeanScout
