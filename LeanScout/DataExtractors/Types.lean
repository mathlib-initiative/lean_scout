module
public meta import LeanScout.InfoTree
public meta import LeanScout.Init
public meta import LeanScout.Schema
public meta import LeanScout.DataExtractors.Utils

open Lean

namespace LeanScout
namespace DataExtractors

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

end DataExtractors
end LeanScout
