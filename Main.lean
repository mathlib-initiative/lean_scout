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
  scoutDir : Option System.FilePath := none
  command : Option Command := none
  targetSpec : Option TargetSpec := none
  dataDir : Option System.FilePath := none
  numShards : Option Nat := none
  batchRows : Option Nat := none
  parquet : Option Unit := none
  jsonl : Option Unit := none
  parallel : Nat := 1

def Config.processArgs (cfg : Config) (args : List String) : Config :=
  match args with
  | "--parallel" :: n :: args =>
    match n.toNat? with | some n => { cfg with parallel := n }.processArgs args | none => cfg.processArgs args
  | "--scoutDir" :: path :: args => { cfg with scoutDir := some <| System.FilePath.mk path }.processArgs args
  | "--command" :: command :: args => { cfg with command := command.toName }.processArgs args
  | "--dataDir" :: path :: args => { cfg with dataDir := some <| System.FilePath.mk path }.processArgs args
  | "--numShards" :: n :: args => { cfg with numShards := n.toNat? }.processArgs args
  | "--batchRows" :: n :: args => { cfg with batchRows := n.toNat? }.processArgs args
  | "--parquet" :: args => { cfg with parquet := some () }.processArgs args
  | "--jsonl" :: args => { cfg with jsonl := some () }.processArgs args
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

structure Writer where
  wait : IO UInt32
  sink : String → IO Unit

unsafe
def run (cfg : Config) : IO UInt32 := do
  let some cmd := cfg.command
    | LeanScout.logger.log .error "No command specified in config" ; return 1
  let some tgtSpec := cfg.targetSpec
    | LeanScout.logger.log .error "No target specified in config" ; return 1
  let some scoutDir := cfg.scoutDir
    | LeanScout.logger.log .error "No scout directory specified in config" ; return 1

  let cfgs : Array Extractor.Config := (← tgtSpec.toTargets).map fun tgt => ⟨cmd, tgt⟩

  let some extractor := (data_extractors).get? cmd
    | logger.log .error s!"No data extractor found for command '{cmd}'" ; return 1

  let mut writerName : String := ""
  match cfg.parquet, cfg.jsonl with
  | none, none =>
    logger.log .error "No output format specified (use --parquet or --jsonl)" ; return 1
  | some _, none =>
    writerName := "parquet"
  | none, some _ =>
    writerName := "jsonl"
  | some _, some _ =>
    logger.log .error "Cannot specify both --parquet and --jsonl" ; return 1

  let writer : Std.Mutex Writer ← Std.Mutex.new <| ← match writerName with
    | "jsonl" => jsonlWriter
    | "parquet" => parquetWriter scoutDir cfg extractor
    | _ => unreachable!

  let mut launches : Array (IO (Task <| Except IO.Error UInt32)) := #[]
  for cfg in cfgs do
    let cfg := Lean.toJson cfg |>.compress
    let args : Array String := #[
      "exe", "-q", "lean_scout_extractor", cfg
    ]
    let task := subprocessLines "lake" args fun s => writer.atomically get >>= fun w => w.sink s
    launches := launches.push task

  let mut taskPool : Std.HashMap Nat (Task <| Except IO.Error UInt32) := {}
  let mut launchIdx := 0
  let mut results : Std.HashMap Nat (Except IO.Error UInt32) := {}

  while launchIdx < launches.size || !taskPool.isEmpty do
    -- Launch new tasks up to max concurrency of 8
    while taskPool.size < 8 && launchIdx < launches.size do
      let task ← launches[launchIdx]!
      logger.log .info s!"Started extractor task {launchIdx}"
      taskPool := taskPool.insert launchIdx task
      launchIdx := launchIdx + 1

    -- Check for completed tasks
    for (idx, task) in taskPool do
      if ← IO.hasFinished task then
        let res ← IO.wait task
        match res with
        | .ok code => logger.log .info s!"Extractor task {idx} finished with exit code {code}"
        | .error err => logger.log .error s!"Extractor task {idx} failed with error: {err}"
        results := results.insert idx res
        taskPool := taskPool.erase idx

    -- Small sleep to avoid busy-waiting
    IO.sleep 10

  writer.atomically <| get >>= fun w => w.wait

where

jsonlWriter : IO Writer := return {
  wait := return 0,
  sink := fun s => do
    let stdout ← IO.getStdout
    stdout.putStrLn s
    stdout.flush
}

parquetWriter (scoutDir : System.FilePath) (cfg : Config) (extractor : DataExtractor) : IO Writer := do
  let dataDir := match cfg.dataDir with | some dataDir => dataDir | none => System.FilePath.mk "./data"
  IO.FS.createDirAll dataDir
  let dataDir ← IO.FS.realPath dataDir
  let batchRows := match cfg.batchRows with | some n => n | none => 1024
  let numShards := match cfg.numShards with | some n => n | none => 128
  let subprocess ← IO.Process.spawn {
    cwd := scoutDir
    cmd := "uv"
    args := #["run", "parquet_writer",
      "--dataDir", dataDir.toString,
      "--batchRows", toString batchRows,
      "--numShards", toString numShards,
      "--key", extractor.key,
      "--schema", (toJson extractor.schema).compress]
    stdin := .piped
  }
  let (stdin, child) ← subprocess.takeStdin
  let stdinRef ← IO.mkRef (some stdin)
  return {
    wait := do
      stdinRef.set none
      child.wait
    sink := fun s => do
      if let some h ← stdinRef.get then
        h.putStrLn s
        h.flush
  }

end Orchestrator

end LeanScout

public unsafe def main (args : List String) : IO UInt32 := do
  let cfg := LeanScout.Orchestrator.Config.processArgs {} args
  LeanScout.Orchestrator.run cfg
