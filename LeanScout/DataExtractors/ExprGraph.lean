module

public import Lean
public import LeanScout.Types

open Lean Std

public section

namespace LeanScout

namespace ExprGraph

def _root_.Lean.MData.toJson (md : MData) : Json :=
  .mkObj <| md.entries.map fun (nm, val) => .mk nm.toString <| match val with
    | .ofString s => .str s
    | .ofName   n => .str n.toString
    | .ofNat    n => .num n
    | .ofInt    n => .num n
    | .ofBool   b => .bool b
    | .ofSyntax s => .str <| toString s.prettyPrint

inductive Node where
  | bvar (id : Nat) : Node
  | cdecl (idx : Nat) (id : FVarId) (nm : Name) (binderInfo : BinderInfo) (kind : LocalDeclKind) : Node
  | ldecl (idx : Nat) (id : FVarId) (nm : Name) (nonDep : Bool) (kind : LocalDeclKind) : Node
  | mvar (mvarId : MVarId) : Node
  | sort (level : Level) : Node
  | const (name : Name) (levels : List Level) : Node
  | app : Node
  | lam (name : Name) (binderInfo : BinderInfo) : Node
  | forallE (name : Name) (binderInfo : BinderInfo) : Node
  | letE (name : Name) (nonDep : Bool) : Node
  | lit (lit : Literal) : Node
  | mdata (md : Json) : Node
  | proj (name : Name) (idx : Nat) : Node
deriving Hashable, BEq

inductive Edge where
  | cdeclType
  | ldeclType
  | ldeclValue
  | mvarType
  | appFn
  | appArg
  | lamBody
  | lamFVar
  | forallEBody
  | forallEFVar
  | letEBody
  | letEFVar
  | mdata
  | proj
deriving Hashable, BEq

end ExprGraph

structure WithId (α : Type) where
  id : UInt64
  val : α
deriving Hashable, BEq

open ExprGraph in
structure ExprGraph where
  nodes : HashSet <| WithId Node
  edges : HashSet <| WithId Edge
  src : HashMap (WithId Edge) (WithId Node)
  tgt : HashMap (WithId Edge) (WithId Node)

namespace ExprGraph

def empty : ExprGraph where
  nodes := {}
  edges := {}
  src := {}
  tgt := {}

def node (node : WithId Node) : ExprGraph where
  nodes := {node}
  edges := {}
  src := {}
  tgt := {}

def union (g1 g2 : ExprGraph) : ExprGraph where
  nodes := g1.nodes.fold (init := g2.nodes) .insert
  edges := g1.edges.fold (init := g2.edges) .insert
  src := g1.src.fold (init := g2.src) .insert
  tgt := g1.tgt.fold (init := g2.tgt) .insert

def addEdge (g : ExprGraph) (edge : WithId Edge) (source target : WithId Node) :
    ExprGraph where
  nodes := g.nodes.insertMany [source, target]
  edges := g.edges.insert edge
  src := g.src.insert edge source
  tgt := g.tgt.insert edge target

def mix (a : α) (b : β) [Hashable α] [Hashable β] : UInt64 :=
  mixHash (hash a) (hash b)

partial
def mkExprGraph (e : Expr) :
    MonadCacheT Expr (WithId Node × ExprGraph) MetaM (WithId Node × ExprGraph) := do
  let lctx := (← getLCtx).sanitizeNames.run' { options := ← getOptions }
  Meta.withLCtx lctx (← Meta.getLocalInstances) do let e ← instantiateMVars e ; checkCache e fun _ => do
    let outId : UInt64 := mix e "Lean.Expr"
    match e with
    | .bvar id =>
      let outNode : WithId Node := ⟨outId, .bvar id⟩
      return (outNode, node outNode)
    | .fvar id =>
      match ← id.getDecl with
      | .cdecl idx id nm tp bi kind =>
        let outNode : WithId Node := ⟨outId, .cdecl idx id nm bi kind⟩
        let (tpNode, tpGraph) ← mkExprGraph tp
        let outGraph := tpGraph.addEdge ⟨outId, .cdeclType⟩ tpNode outNode
        return (outNode, outGraph)
      | .ldecl idx id nm tp val nonDep kind =>
        let outNode : WithId Node := ⟨outId, .ldecl idx id nm nonDep kind⟩
        let (tpNode, tpGraph) ← mkExprGraph tp
        let (valNode, valGraph) ← mkExprGraph val
        let outGraph := tpGraph.union valGraph
          |>.addEdge ⟨outId, .ldeclType⟩ tpNode outNode
          |>.addEdge ⟨outId, .ldeclValue⟩ valNode outNode
        return (outNode, outGraph)
    | .mvar id =>
      let outNode : WithId Node := ⟨outId, .mvar id⟩
      let tp ← Meta.inferType e
      let (tpNode, tpGraph) ← mkExprGraph tp
      let outGraph := tpGraph.addEdge ⟨outId, .mvarType⟩ tpNode outNode
      return (outNode, outGraph)
    | .sort level =>
      let outNode : WithId Node := ⟨outId, .sort level⟩
      return (outNode, node outNode)
    | .const name levels =>
      let outNode : WithId Node := ⟨outId, .const name levels⟩
      return (outNode, node outNode)
    | .app fn arg =>
      let (fnNode, fnGraph) ← mkExprGraph fn
      let (argNode, argGraph) ← mkExprGraph arg
      let outNode : WithId Node := ⟨outId, .app⟩
      let outGraph := fnGraph.union argGraph
        |>.addEdge ⟨outId, .appFn⟩ fnNode outNode
        |>.addEdge ⟨outId, .appArg⟩ argNode outNode
      return (outNode, outGraph)
    | .lam nm tp body bi => Meta.withLocalDecl nm bi tp fun fvar => do
      let body := body.instantiateRev #[fvar]
      let (bodyNode, bodyGraph) ← mkExprGraph body
      let (varNode, varGraph) ← mkExprGraph fvar
      let outNode : WithId Node := ⟨outId, .lam nm bi⟩
      let outGraph := bodyGraph.union varGraph
        |>.addEdge ⟨outId, .lamBody⟩ bodyNode outNode
        |>.addEdge ⟨outId, .lamFVar⟩ varNode outNode
      return (outNode, outGraph)
    | .forallE nm tp body bi => Meta.withLocalDecl nm bi tp fun fvar => do
      let body := body.instantiateRev #[fvar]
      let (bodyNode, bodyGraph) ← mkExprGraph body
      let (varNode, varGraph) ← mkExprGraph fvar
      let outNode : WithId Node := ⟨outId, .forallE nm bi⟩
      let outGraph := bodyGraph.union varGraph
        |>.addEdge ⟨outId, .forallEBody⟩ bodyNode outNode
        |>.addEdge ⟨outId, .forallEFVar⟩ varNode outNode
      return (outNode, outGraph)
    | .letE nm tp val body nonDep => Meta.withLetDecl (nondep := nonDep) nm tp val fun fvar => do
      let body := body.instantiateRev #[fvar]
      let (bodyNode, bodyGraph) ← mkExprGraph body
      let (varNode, varGraph) ← mkExprGraph fvar
      let outNode : WithId Node := ⟨outId, .letE nm nonDep⟩
      let outGraph := bodyGraph.union varGraph
        |>.addEdge ⟨outId, .letEBody⟩ bodyNode outNode
        |>.addEdge ⟨outId, .letEFVar⟩ varNode outNode
      return (outNode, outGraph)
    | .lit lit =>
      let outNode : WithId Node := ⟨outId, .lit lit⟩
      return (outNode, node outNode)
    | .mdata md expr =>
      let (exprNode, exprGraph) ← mkExprGraph expr
      let outNode : WithId Node := ⟨outId, .mdata md.toJson⟩
      let outGraph := exprGraph.addEdge ⟨outId, .mdata⟩ exprNode outNode
      return (outNode, outGraph)
    | .proj nm idx struct =>
      let (structNode, structGraph) ← mkExprGraph struct
      let outNode : WithId Node := ⟨outId, .proj nm idx⟩
      let outGraph := structGraph.addEdge ⟨outId, .proj⟩ structNode outNode
      return (outNode, outGraph)

def mkExprGraphWithLCtx (e : Expr) :
    MonadCacheT Expr (WithId Node × ExprGraph) MetaM (WithId Node × ExprGraph) := do
  let (exprNode, exprGraph) ← mkExprGraph e
  let mut outGraph := exprGraph
  for decl in ← getLCtx do
    let (_, declGraph) ← mkExprGraph <| .fvar decl.fvarId
    outGraph := outGraph.union declGraph
  return (exprNode, outGraph)

def serialize
    (g : ExprGraph)
    (root : Option (WithId Node) := none)
    (serializeNode : Node → String)
    (serializeEdge : Edge → String) :
    Json := Id.run do
  let mut nodes : Array Json := {}
  let mut nodeToIdx : Std.HashMap (WithId Node) Nat := {}
  for node in g.nodes do
    nodeToIdx := nodeToIdx.insert node nodes.size
    nodes := nodes.push <| json% {
      idx : $(nodes.size),
      node : $(serializeNode node.val)
    }
  let mut edges : Array Json := {}
  for edge in g.edges do
    let some src := g.src.get? edge | continue
    let some tgt := g.tgt.get? edge | continue
    let some srcIdx := nodeToIdx.get? src | continue
    let some tgtIdx := nodeToIdx.get? tgt | continue
    edges := edges.push <| json% {
      src : $(srcIdx),
      tgt : $(tgtIdx),
      edge : $(serializeEdge edge.val)
    }
  let rootIdx : Option Nat := do
    let r ← root
    let idx ← nodeToIdx.get? r
    return idx
  return json% {
    nodes : $(nodes),
    edges : $(edges),
    rootIdx : $(rootIdx)
  }

def nodeSchema : Schema := .mk [
  { name := "idx", nullable := false, type := .nat },
  { name := "node", nullable := false, type := .string },
]

def edgeSchema : Schema := .mk [
  { name := "src", nullable := false, type := .nat },
  { name := "tgt", nullable := false, type := .nat },
  { name := "edge", nullable := false, type := .string },
]

def graphSchema : Schema := .mk [
  { name := "nodes", nullable := false, type := .list (.struct <| nodeSchema.fields) },
  { name := "edges", nullable := false, type := .list (.struct <| edgeSchema.fields) },
  { name := "rootIdx", nullable := true, type := .nat }
]

end ExprGraph

end LeanScout
