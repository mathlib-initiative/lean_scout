import Lake

open Lake DSL
open System

package lean_scout

@[default_target]
lean_lib LeanScout

lean_exe lean_scout where
  root := `Main
  supportInterpreter := true

library_facet data (lib) : Array FilePath := pure <$> do
  let scoutExe ← (← «lean_scout».fetch).await
  let modules ← (← lib.modules.fetch).await
  let dataDir := (← getRootPackage).buildDir / "data"
  modules.mapM fun module => do
    let path : FilePath := dataDir / toString module
    buildFileUnlessUpToDate' path do
      proc {
        cmd := scoutExe.toString
        args := #[dataDir.toString, path.toString, toString module]
      }
    return path
