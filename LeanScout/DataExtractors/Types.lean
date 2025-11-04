module
public import LeanScout.DataExtractors.Utils
public import LeanScout.Frontend
public import LeanScout.Init

open Lean

namespace LeanScout
namespace DataExtractors

@[data_extractor types]
public unsafe def types : DataExtractor where
  schema := .mk [
    { name := "name", nullable := false, type := .string },
    { name := "module", nullable := true, type := .string },
    { name := "type", nullable := false, type := .string },
  ]
  key := "name"
  go handle
  | .imports tgt => tgt.runCoreM <| Meta.MetaM.run' do
    let env ← getEnv
    for (n, c) in env.constants do
      if ← declNameFilter n then continue
      let mod : Option Name := match env.getModuleIdxFor? n with
      | some idx => env.header.moduleNames[idx]!
      | none => if env.constants.map₂.contains n then env.header.mainModule else none
      handle.putStrLn <| Json.compress <| json% {
        name : $(n),
        module : $(mod),
        type : $(s!"{← Meta.ppExpr c.type}")
      }
  | _ => throw <| .userError "Unsupported Target"

end DataExtractors
end LeanScout
