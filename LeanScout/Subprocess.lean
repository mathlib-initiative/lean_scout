module

public import Lean

namespace LeanScout

partial
def subprocessLines (go : String → IO Unit) (cmd : String) (args : Array String) :
    IO (Task <| Except IO.Error UInt32) := do
  let child ← IO.Process.spawn {
    cmd := cmd
    args := args
    stdout := .piped
  }
  IO.asTask do
    processLines child.kill child.stdout
    child.wait
where processLines (kill : IO Unit) (stdout : IO.FS.Handle) : IO Unit := do
    if ← IO.checkCanceled then
      kill
      return
    let line ← stdout.getLine
    if line.isEmpty then return
    go line.trimRight
    processLines kill stdout

end LeanScout
