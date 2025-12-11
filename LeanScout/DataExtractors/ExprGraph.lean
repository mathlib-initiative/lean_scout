module

import Lean
open Lean Std

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
  | bvar : Nat → Node
  | fvar : FVarId → Node
  | mvar : MVarId → Node
  | sort : Level → Node
  | const : Name → List Level → Node
  | app : Node
  | lam : Name → BinderInfo → Node
  | forallE : Name → BinderInfo → Node
  | letE : Name → Bool → Node
  | lit : Literal → Node
  | mdata : Json → Node
  | proj : Name → Nat → Node
deriving Hashable, BEq

inductive Edge where
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

def mkExprGraph (e : Expr) : MonadCacheT Expr (WithId Node × ExprGraph) MetaM (WithId Node × ExprGraph) := do
  let e ← instantiateMVars e
  checkCache e fun _ => do
    let outId : UInt64 := mix e "Lean.Expr"
    match e with
    | .bvar id =>
      let outNode : WithId Node := ⟨outId, .bvar id⟩
      return (outNode, node outNode)
    | .fvar id =>
      match ← id.getDecl with
      | .cdecl idx id nm tp bi kind => _
      | .ldecl idx id nm tp val nonDep kind => _
    | _ => sorry

end ExprGraph

end LeanScout
