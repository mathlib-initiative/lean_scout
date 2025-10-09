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

library_facet module_paths (lib) : System.FilePath := do
  let modules ← (← lib.modules.fetch).await
  let path : System.FilePath := "module_paths"
  let handle ← IO.FS.Handle.mk path .write
  for module in modules do
    handle.putStrLn <| module.filePath module.pkg.rootDir "lean" |>.toString
  return pure path

script scout (args) := do
  let workspace ← getWorkspace
  let some scout := workspace.findPackage? `lean_scout |
    throw <| .userError "Failed to find lean_scout dependency"
  let child ← IO.Process.spawn {
    cmd := "lake"
    args := #["exe", "lean_scout", scout.rootDir.toString] ++ args.toArray
  }
  child.wait
