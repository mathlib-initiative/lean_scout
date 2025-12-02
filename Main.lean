module

public import LeanScout

namespace LeanScout

namespace Orchestrator

open Lean

inductive TargetSpec where
  | imports (names : Array String)
  | read (path : System.FilePath)
  | library (name : Name)

structure Config where
  command : Option Command := none
  targetSpec : Option TargetSpec := none

def Config.processArgs (cfg : Config) (args : List String) : Config :=
  match args with
  | "--command" :: command :: args => { cfg with command := command.toName }.processArgs args
  | "--imports" :: importsList => { cfg with targetSpec := some <| .imports <| importsList.toArray }
  | "--read" :: [path] => { cfg with targetSpec := some <| .read <| System.FilePath.mk path }
  | "--library" :: [name] => { cfg with targetSpec := some <| .library <| name.toName }
  | _ => cfg

def TargetSpec.toTargets : TargetSpec → IO (Array Target)
  | .imports names => return #[.mkImports names]
  | .read path => return #[.read path]
  | .library name => do
    let output ← IO.Process.output {
      cmd := "lake"
      args := #["query", "-q", s!"{name}:module_paths"]
    }
    let lines := output.stdout.splitOn "\n" |>.filter (·.trim ≠ "")
    return lines.toArray.map fun s => .read <| System.FilePath.mk s

#eval discard <| TargetSpec.toTargets (.library `LeanScout)

def run (cfg : Config) : IO UInt32 := do
  let some cmd := cfg.command
    | LeanScout.logger.log .error "No command specified in config" ; return 1
  let some tgtSpec := cfg.targetSpec
    | LeanScout.logger.log .error "No target specified in config" ; return 1
  let cfgs : Array Extractor.Config := (← tgtSpec.toTargets).map fun tgt => ⟨cmd, tgt⟩
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

public def main (args : List String) : IO UInt32 := do
  let cfg := LeanScout.Orchestrator.Config.processArgs {} args
  LeanScout.Orchestrator.run cfg
