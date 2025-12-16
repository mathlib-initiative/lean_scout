import Lake

open Lake DSL
open System

package lean_scout where
  leanOptions := #[
    ⟨`experimental.module, true⟩
  ]
  testDriver := "LeanScoutTest"

lean_lib LeanScoutTest

@[default_target]
lean_lib LeanScout

@[default_target]
lean_exe lean_scout_extractor where
  root := `Extractor
  supportInterpreter := true

@[default_target]
lean_exe lean_scout where
  root := `Main
  supportInterpreter := true

@[default_target]
lean_exe lean_scout_schema where
  root := `ScoutSchema

library_facet module_paths (lib) : Array System.FilePath := do
  let modules ← (← lib.modules.fetch).await
  let mut out := #[]
  for module in modules do
    out := out.push <| module.filePath module.pkg.rootDir "lean"
  return pure out

script scout (args) := do
  let workspace ← getWorkspace
  let some scout := workspace.findPackageByName? `lean_scout |
    throw <| .userError "Failed to find lean_scout dependency"
  let scoutRoot := scout.rootDir
  let child ← IO.Process.spawn {
    cmd := "lake",
    args := #["exe", "lean_scout", "--scoutDir", scoutRoot.toString] ++ args,
  }
  child.wait
