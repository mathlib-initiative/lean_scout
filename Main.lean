module

public import LeanScout

namespace LeanScout

namespace Orchestrator

open Lean

inductive TargetSpec where
  | imports (names : Array String)
  | read (paths : List System.FilePath)
  | library (name : Name)

inductive WriterSpec where
  | parquet
  | jsonl

structure Config where
  scoutDir : Option System.FilePath := none
  command : Option Command := none
  targetSpec : Option TargetSpec := none
  dataDir : Option System.FilePath := none
  writerSpec : Option WriterSpec := none
  numShards : Nat := 128
  batchRows : Nat := 1024
  parallel : Nat := 1
  errors : Array String := #[]

def Config.processArgs (cfg : Config) (args : List String) : Config :=
  match args with
  | "--parallel" :: nStr :: args =>
    match nStr.toNat? with
    | some n => { cfg with parallel := n }.processArgs args
    | none => { cfg with errors := cfg.errors.push s!"Invalid value for --parallel: '{nStr}'" }.processArgs args
  | "--scoutDir" :: path :: args => { cfg with scoutDir := some <| System.FilePath.mk path }.processArgs args
  | "--command" :: command :: args => { cfg with command := command.toName }.processArgs args
  | "--dataDir" :: path :: args => { cfg with dataDir := some <| System.FilePath.mk path }.processArgs args
  | "--numShards" :: nStr :: args =>
    match nStr.toNat? with
    | some n => { cfg with numShards := n }.processArgs args
    | none => { cfg with errors := cfg.errors.push s!"Invalid value for --numShards: '{nStr}'" }.processArgs args
  | "--batchRows" :: nStr :: args =>
    match nStr.toNat? with
    | some n => { cfg with batchRows := n }.processArgs args
    | none => { cfg with errors := cfg.errors.push s!"Invalid value for --batchRows: '{nStr}'" }.processArgs args
  | "--parquet" :: args => { cfg with writerSpec := some .parquet }.processArgs args
  | "--jsonl" :: args => { cfg with writerSpec := some .jsonl }.processArgs args
  | "--imports" :: importsList => { cfg with targetSpec := some <| .imports <| importsList.toArray }
  | "--read" :: paths@(_ :: _) => { cfg with targetSpec := some <| .read <| paths.map System.FilePath.mk }
  | "--library" :: [name] => { cfg with targetSpec := some <| .library <| name.toName }
  | [] => cfg
  | unknown :: args => { cfg with errors := cfg.errors.push s!"Unknown argument: '{unknown}'" }.processArgs args

def TargetSpec.toTargets : TargetSpec → IO (Array Target)
  | .imports names => return #[.mkImports names]
  | .read paths => return paths.toArray.map fun p => .read p
  | .library name => do
    let output ← IO.Process.output {
      cmd := "lake"
      args := #["query", "-q", s!"{name}:module_paths"]
    }
    if output.exitCode != 0 then
      throw <| IO.userError s!"lake query failed for library '{name}': {output.stderr.trim}"
    let lines := output.stdout.splitOn "\n" |>.filter (·.trim ≠ "")
    if lines.isEmpty then
      throw <| IO.userError s!"No modules found for library '{name}'"
    return lines.toArray.map fun s => .read <| System.FilePath.mk s

structure Writer where
  wait : IO UInt32
  sink : String → IO Unit

-- unsafe because `data_extractors` elaborator runs in meta context
unsafe
def run (cfg : Config) : IO UInt32 := do
  -- Check for argument parsing errors
  if !cfg.errors.isEmpty then
    for err in cfg.errors do
      logger.log .error err
    return 1

  let some cmd := cfg.command
    | logger.log .error "No command specified (use --command)" ; return 1
  let some tgtSpec := cfg.targetSpec
    | logger.log .error "No target specified (use --imports, --library, or --read)" ; return 1
  let some scoutDir := cfg.scoutDir
    | logger.log .error "No scout directory specified (use --scoutDir)" ; return 1
  let some writerSpec := cfg.writerSpec
    | logger.log .error "No writer specified (use --parquet or --jsonl)" ; return 1

  let cfgs : Array Extractor.Config := (← tgtSpec.toTargets).map fun tgt => ⟨cmd, tgt⟩

  let some extractor := (data_extractors).get? cmd
    | logger.log .error s!"No data extractor found for command '{cmd}'" ; return 1

  let writer : Std.Mutex Writer ← Std.Mutex.new <| ← match writerSpec with
  | .jsonl => jsonlWriter
  | .parquet => parquetWriter scoutDir cfg extractor

  let mut launches : Array (String × IO (Task <| Except IO.Error UInt32)) := #[]
  for cfg in cfgs do
    let cfgArg := Lean.toJson cfg |>.compress
    let args : Array String := #[
      "exe", "-q", "lean_scout_extractor", cfgArg
    ]
    let task := subprocessLines "lake" args fun s => writer.atomically get >>= fun w => w.sink s
    launches := launches.push (cfgArg, task)

  let mut taskPool : Std.HashMap Nat (Task <| Except IO.Error UInt32) := {}
  let mut launchIdx := 0
  let mut results : Std.HashMap Nat (Except IO.Error UInt32) := {}

  while launchIdx < launches.size || !taskPool.isEmpty do

    -- Launch new tasks up to configured parallelism
    while taskPool.size < cfg.parallel && launchIdx < launches.size do
      let (cfgArg, task) := launches[launchIdx]!
      logger.log .info s!"Started extractor task {launchIdx} with config {cfgArg}"
      taskPool := taskPool.insert launchIdx (← task)
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

  let writerCode ← writer.atomically <| get >>= fun w => w.wait

  -- Check if any extractor failed
  let mut hasFailure := writerCode != 0
  for (_, res) in results do
    match res with
    | .ok code => if code != 0 then hasFailure := true
    | .error _ => hasFailure := true

  if hasFailure then return 1
  return 0

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
  let subprocess ← IO.Process.spawn {
    cwd := scoutDir
    cmd := "uv"
    args := #["run", "parquet_writer",
      "--dataDir", dataDir.toString,
      "--batchRows", toString cfg.batchRows,
      "--numShards", toString cfg.numShards,
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

open LeanScout Orchestrator in
public unsafe def main (args : List String) : IO UInt32 := do
  run <| Config.processArgs {} args
