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

module_facet data (module) : FilePath := pure <$> do
  let scoutExe ← (← «lean_scout».fetch).await
  let dataDir := (← getRootPackage).buildDir / "data"
  let moduleSrcFile := module.filePath module.pkg.rootDir "lean"
  let moduleDataFile := module.filePath dataDir "data"
  buildFileUnlessUpToDate' moduleDataFile do
    proc {
      cmd := scoutExe.toString
      args := #[moduleSrcFile.toString, moduleDataFile.toString]
    }
  return moduleDataFile

library_facet data (lib) : Array FilePath := do
  let modules ← (← lib.modules.fetch).await
  return Job.collectArray <| ← modules.mapM fun mod => mod.facet `data |>.fetch
