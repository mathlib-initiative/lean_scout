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
    { name := "allowCompletion", nullable := false, type := .bool },
  ]
  key := "name"
  go config sink opts
  | .imports tgt => do
    let cfg ← match parseTaskLimitConfig "const_dep" config with
      | .ok cfg => pure cfg
      | .error err => throw <| IO.userError err
    tgt.runParallelCoreM opts (maxTasks := cfg.taskLimit) fun env n c => Meta.MetaM.run' do
      let mod : Option Name := match env.getModuleIdxFor? n with
        | some idx => env.header.moduleNames[idx]!
        | none => if env.constants.map₂.contains n then env.header.mainModule else none
      let deps : Array String := c.getUsedConstantsAsSet.toArray.map fun nm => nm.toString
      let allowCompletion := Lean.Meta.allowCompletion env n
      sink <| json% {
        name : $(n),
        module : $(mod),
        deps : $(deps),
        allowCompletion : $(allowCompletion)
      }
  | _ => throw <| IO.userError "Unsupported Target"

end DataExtractors
end LeanScout
