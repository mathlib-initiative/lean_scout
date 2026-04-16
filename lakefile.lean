import Lake

open Lake DSL
open System

package lean_scout where
  leanOptions := #[
    ⟨`experimental.module, true⟩
  ]

lean_lib LeanScoutTest

@[test_driver]
lean_exe test_lean_scout where
  root := `TestLeanScout

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

structure LibraryModuleData where
  name : Lean.Name
  path : System.FilePath
  setupFile : System.FilePath
  deriving Repr, Lean.ToJson, Lean.FromJson

library_facet module_paths (lib) : Array System.FilePath := do
  let modules ← (← lib.modules.fetch).await
  let mut out := #[]
  for module in modules do
    out := out.push <| module.filePath module.pkg.rootDir "lean"
  return pure out

library_facet moduleData (lib) : Array LibraryModuleData := do
  let modules ← (← lib.modules.fetch).await
  let mut out := #[]
  for module in modules do
    let setup ← (← module.setup.fetch).await
    let setupFile := module.setupFile
    match setupFile.parent with
    | some parent => IO.FS.createDirAll parent
    | none => pure ()
    IO.FS.writeFile setupFile (Lean.toJson setup).pretty
    out := out.push {
      name := module.name
      path := module.filePath module.pkg.rootDir "lean"
      setupFile := setupFile
    }
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
