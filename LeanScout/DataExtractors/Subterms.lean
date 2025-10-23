module
public meta import LeanScout.InfoTree
public meta import LeanScout.Init
public meta import LeanScout.Schema
public meta import LeanScout.DataExtractors.Utils

namespace LeanScout
namespace DataExtractors

open Lean

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

end DataExtractors
end LeanScout
