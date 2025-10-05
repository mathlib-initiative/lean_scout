import Lake

open Lake DSL
open System

package lean_scout where
  leanOptions := #[
    ⟨`experimental.module, true⟩
  ]

@[default_target]
lean_lib LeanScout

lean_exe lean_scout where
  root := `Main
  supportInterpreter := true

module_facet tactics (module) : Unit := pure <$> do
  let scoutExe ← (← «lean_scout».fetch).await
  let moduleSrcFile := module.filePath module.pkg.rootDir "lean"
  let outPath := module.filePath "." "jsonl"
  proc {
    cmd := scoutExe.toString
    args := #["tactics", "data", outPath.toString, "read", moduleSrcFile.toString]
  }

library_facet tactics (lib) : Unit := do
  let modules ← (← lib.modules.fetch).await
  return discard <| Job.collectArray <| ← modules.mapM fun mod => mod.facet `tactics |>.fetch

script scout (args) := do
  let workspace ← getWorkspace
  let some scout := workspace.findPackage? `lean_scout |
    throw <| .userError "Failed to find lean_scout dependency"
  let child ← IO.Process.spawn {
    cmd := "lake"
    args := #["exe", "lean_scout", scout.rootDir.toString] ++ args.toArray
  }
  child.wait
