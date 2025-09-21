import Lake

open Lake DSL
open System

package lean_scout where
  leanOptions := #[
    ⟨`experimental.module, true⟩
  ]

@[default_target]
lean_lib LeanScout

lean_exe scout where
  root := `Main
  supportInterpreter := true

module_facet tactics (module) : Unit := pure <$> do
  let scoutExe ← (← «scout».fetch).await
  let moduleSrcFile := module.filePath module.pkg.rootDir "lean"
  let outPath := module.filePath "." "jsonl"
  proc {
    cmd := scoutExe.toString
    args := #["tactics", outPath.toString, "read", moduleSrcFile.toString]
  }

library_facet tactics (lib) : Unit := do
  let modules ← (← lib.modules.fetch).await
  return discard <| Job.collectArray <| ← modules.mapM fun mod => mod.facet `tactics |>.fetch
