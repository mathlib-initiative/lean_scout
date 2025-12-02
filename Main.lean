module

public import LeanScout

namespace LeanScout

namespace Orchestrator

structure Config where
  command : Command
  targets : Array Target

def run (cfg : Config) : IO UInt32 := do
  let cfgs : Array Extractor.Config := cfg.targets.map fun tgt => ⟨cfg.command, tgt⟩
  let stdout ← IO.getStdout
  let writer : Std.Mutex IO.FS.Stream ← Std.Mutex.new <| stdout
  let write (s : String) : IO Unit := writer.atomically do
    let stdout ← get
    stdout.putStrLn s
    stdout.flush
  let mut taskPool : Array (Task <| Except IO.Error UInt32) := #[]
  for cfg in cfgs do
    let cfg := Lean.toJson cfg |>.compress
    let args : Array String := #[
      "exe", "-q", "lean_scout_extractor", cfg
    ]
    let task ← subprocessLines "lake" args write
    logger.log .info s!"Started extractor task with config {cfg}"
    taskPool := taskPool.push task
  return 0

end Orchestrator

end LeanScout
