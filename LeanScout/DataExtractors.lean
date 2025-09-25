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

section Subterms

private meta def exprWithLCtx (e : Expr) : MetaM Json := do
  let mut varFmts : Array (Name × Format × Option Format) := #[]
  let lctx := (← getLCtx).sanitizeNames.run' { options := (← getOptions) } |>.run
  let typeFmt ← Meta.ppExpr e
  for decl in lctx do
    if decl.isAuxDecl || decl.isImplementationDetail then continue
    match decl with
    | .cdecl _ _ nm tp _ .. =>
      varFmts := varFmts.push (nm, ← Meta.ppExpr tp, none)
    | .ldecl _ _ nm tp val .. =>
      varFmts := varFmts.push (nm, ← Meta.ppExpr tp, ← Meta.ppExpr val)
  let lctx : Array Json := varFmts.map fun (nm, tp, val?) => json%{
    name : $(nm),
    type : $(tp.pretty),
    val? : $(val?.map fun fmt => fmt.pretty)
  }
  return json%{
      expr : $(typeFmt.pretty),
      lctx : $(lctx)
    }

private meta def writeSubterms
    (handle : IO.FS.Handle)
    (kind : String)
    (parent : Name)
    (e : Expr) : MetaM Unit := do
  Meta.forEachExpr e fun e => do
    let datapoint ← exprWithLCtx e
    handle.putStrLn <| Json.compress <| json% {
      kind : $(kind),
      parent : $(parent),
      expr : $(datapoint)
    }

@[data_extractor]
public meta unsafe def subterms : DataExtractor where
  command := "subterms"
  go handle tgt := { tgt with opts := maxHeartbeats.set {} 0 }.runCoreM <| Meta.MetaM.run' do
    let env ← getEnv
    for (n, c) in env.constants do
      if ← declNameFilter n then continue
      println! n
      let env ← getEnv
      let module := env.getModuleIdxFor? n |>.map fun modIdx =>
        env.header.moduleNames[modIdx]!
      let tp := ← Meta.ppExpr c.type
      let val ← c.value?.mapM Meta.ppExpr
      let parent : Json := json% {
        kind : "constant",
        name : $(n),
        module : $(module),
        type : $(tp.pretty),
        val : $(val.map Format.pretty)
      }
      handle.putStrLn parent.compress
      writeSubterms handle "typeSubterm" n c.type
      if let some val := c.value? then
        writeSubterms handle "valueSubterms" n val

private meta def writeSubtermsWithTypes
    (handle : IO.FS.Handle)
    (kind : String)
    (parent : Name)
    (e : Expr) : MetaM Unit := do
  Meta.forEachExpr e fun e => do
    let datapoint ← exprWithLCtx e
    let datapointType ← exprWithLCtx <| ← Meta.inferType e
    handle.putStrLn <| Json.compress <| json% {
      kind : $(kind),
      parent : $(parent),
      expr : $(datapoint),
      type : $(datapointType)
    }

@[data_extractor]
public meta unsafe def subtermsWithTypes : DataExtractor where
  command := "subtermsWithTypes"
  go handle tgt := { tgt with opts := maxHeartbeats.set {} 0 }.runCoreM <| Meta.MetaM.run' do
    let env ← getEnv
    for (n, c) in env.constants do
      if ← declNameFilter n then continue
      println! n
      let env ← getEnv
      let module := env.getModuleIdxFor? n |>.map fun modIdx =>
        env.header.moduleNames[modIdx]!
      let tp := ← Meta.ppExpr c.type
      let val ← c.value?.mapM Meta.ppExpr
      let parent : Json := json% {
        kind : "constant",
        name : $(n),
        module : $(module),
        type : $(tp.pretty),
        val : $(val.map Format.pretty)
      }
      handle.putStrLn parent.compress
      writeSubtermsWithTypes handle "typeSubterm" n c.type
      if let some val := c.value? then
        writeSubtermsWithTypes handle "valueSubterms" n val

end Subterms

end LeanScout
