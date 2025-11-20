import Lean
import Lake.CLI.Main

open Lean

def main : IO Unit := do
  println! "test"
  initSearchPath (← findSysroot)
  let (elanInstall?, leanInstall?, lakeInstall?) ← Lake.findInstall?
  let config ← Lake.MonadError.runEIO <| Lake.mkLoadConfig { elanInstall?, leanInstall?, lakeInstall? }
  let some workspace ← Lake.loadWorkspace config |>.toBaseIO
    | throw <| IO.userError "failed to load Lake workspace"
  let packageName := workspace.root.name
  println! packageName
