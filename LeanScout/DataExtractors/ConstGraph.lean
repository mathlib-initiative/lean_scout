module
public import LeanScout.DataExtractors.Utils
public import LeanScout.Frontend
public import LeanScout.Init
public import LeanScout.DataExtractors.ExprGraph

open Lean

namespace LeanScout
namespace DataExtractors

open ExprGraph

@[data_extractor const_graph]
public unsafe def constGraph : DataExtractor where
  schema := .mk [
    { name := "name", nullable := false, type := .string },
    { name := "graph", nullable := false, type := .struct graphSchema.fields }
  ]
  key := "name"
  go _config sink opts
  | .imports tgt => do
    discard <| tgt.runParallelCoreM opts fun _ n c => Meta.MetaM.run' do
      let (tpNode, tpGraph) ← mkExprGraph c.type |>.run
      let serialized := tpGraph.serialize (tpNode) serializeNode serializeEdge
      sink <| json% {
        name : $(n),
        graph : $(serialized)
      }
      return
  | _ => throw <| IO.userError "Unsupported Target"
where
serializeNode : Node → String
  | .const nm _ => s!"const: {nm}"
  | .bvar .. => "bvar"
  | .mvar .. => "mvar"
  | .cdecl .. => "cdecl"
  | .ldecl .. => "ldecl"
  | .sort .. => "sort"
  | .app => "app"
  | .lam .. => "lam"
  | .forallE .. => "forallE"
  | .letE .. => "letE"
  | .lit .. => "lit"
  | .mdata .. => "mdata"
  | .proj .. => "proj"
serializeEdge : Edge → String
  | .cdeclType => "cdeclType"
  | .ldeclType => "ldeclType"
  | .ldeclValue => "ldeclValue"
  | .mvarType => "mvarType"
  | .appFn => "appFn"
  | .appArg => "appArg"
  | .lamBody => "lamBody"
  | .lamFVar => "lamFVar"
  | .forallEBody => "forallEBody"
  | .forallEFVar => "forallEFVar"
  | .letEBody => "letEBody"
  | .letEFVar => "letEFVar"
  | .mdata => "mdata"
  | .proj => "proj"

end DataExtractors
end LeanScout
