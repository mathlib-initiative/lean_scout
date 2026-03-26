module

public import Lean

namespace LeanScout

public structure RunningSubprocess where
  task : Task (Except IO.Error UInt32)
  cancel : IO Unit

namespace RunningSubprocess

public def wait (subprocess : RunningSubprocess) : IO (Except IO.Error UInt32) :=
  IO.wait subprocess.task

end RunningSubprocess

private def ignoreErrors (action : IO Unit) : IO Unit := do
  try
    action
  catch _ =>
    pure ()

public partial
def subprocessLines (cmd : String) (args : Array String) (go : String → IO Unit) :
    IO RunningSubprocess := do
  let child ← IO.Process.spawn {
    cmd := cmd
    args := args
    stdout := .piped
  }
  let cancel := ignoreErrors child.kill
  let task ← IO.asTask do
    try
      processLines cancel child.stdout
      child.wait
    catch e =>
      cancel
      ignoreErrors (discard <| child.wait)
      throw e
  return { task, cancel }
where
  processLines (kill : IO Unit) (stdout : IO.FS.Handle) : IO Unit := do
    if ← IO.checkCanceled then
      kill
      return
    let line ← stdout.getLine
    if line.isEmpty then return
    go line.trimAsciiEnd.toString
    processLines kill stdout

end LeanScout
