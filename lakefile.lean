import Lake

open Lake DSL
open System

package lean_scout where
  leanOptions := #[
    ⟨`experimental.module, true⟩
  ]
  testDriver := "LeanScoutTest"

lean_lib LeanScoutTest where
  globs := #[.submodules `LeanScoutTest]

@[default_target]
lean_lib LeanScout

lean_exe lean_scout where
  root := `Main
  supportInterpreter := true

lean_exe shake where
  root := `Shake
  supportInterpreter := true


library_facet module_paths (lib) : Array System.FilePath := do
  let modules ← (← lib.modules.fetch).await
  let mut out := #[]
  for module in modules do
    out := out.push <| module.filePath module.pkg.rootDir "lean"
  return pure out

script scout (args) := do
  let workspace ← getWorkspace
  let some scout := workspace.findPackage? `lean_scout |
    throw <| .userError "Failed to find lean_scout dependency"
  let child ← IO.Process.spawn {
    cmd := "uv"
    cwd := scout.rootDir
    args := #["run", "lean-scout", "--scoutPath", scout.rootDir.toString] ++ args.toArray
  }
  child.wait
