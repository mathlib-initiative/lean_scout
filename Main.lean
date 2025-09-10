import LeanScout

def main (args : List String) : IO Unit := do
  let some buildDir := args[0]? | throw <| .userError "Build dir expected"
  IO.FS.createDirAll <| .mk buildDir
  let some path := args[1]? | throw <| .userError "Path expected"
  let some mod := args[2]? | throw <| .userError "Module expected"
  IO.FS.withFile (.mk path) .write fun handle => do
    handle.putStrLn mod
