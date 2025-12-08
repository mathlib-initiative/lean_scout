module
public import LeanScout.DataExtractors.Utils
public import LeanScout.Frontend
public import LeanScout.Init

open Lean

namespace LeanScout
namespace DataExtractors

@[data_extractor const_dep]
public unsafe def constDep : DataExtractor where
  schema := .mk [
    { name := "name", nullable := false, type := .string },
    { name := "module", nullable := true, type := .string },
    { name := "deps", nullable := false, type := .list .string },
  ]
  key := "name"
  go config sink opts
  | .imports tgt => do
    let filter? := match config.getObjValAs? Bool "filter" with
      | .ok b => b
      | .error _ => false
    discard <| tgt.runParallelCoreM opts fun env n c => Meta.MetaM.run' do
      if filter? && (← declNameFilter n) then return
      let mod : Option Name := match env.getModuleIdxFor? n with
        | some idx => env.header.moduleNames[idx]!
        | none => if env.constants.map₂.contains n then env.header.mainModule else none
      let deps : Array String ← c.getUsedConstantsAsSet.toArray |>.filterMapM fun nm => do
        if filter? && (← declNameFilter nm) then return none else return nm.toString
      sink <| json% {
        name : $(n),
        module : $(mod),
        deps : $(deps)
      }
  | _ => throw <| IO.userError "Unsupported Target"

end DataExtractors
end LeanScout
