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
  scoutDir : System.FilePath
  cmdRoot : System.FilePath
  command : Command
  targetSpec : TargetSpec
  writerSpec : WriterSpec
  dataDir : System.FilePath
  numShards : Nat
  batchRows : Nat
  parallel : Nat

private structure ArgState where
  scoutDir : Option System.FilePath := none
  cmdRoot : Option System.FilePath := none
  command : Option Command := none
  targetSpec : Option TargetSpec := none
  writerSpec : Option WriterSpec := none
  dataDir : Option System.FilePath := none
  numShards : Option Nat := none
  batchRows : Option Nat := none
  parallel : Option Nat := none

private def resolvePath (cmdRoot : System.FilePath) (path : System.FilePath) : System.FilePath :=
  if path.isAbsolute then path else cmdRoot / path

private def ArgState.toConfig (s : ArgState) : Except String Config := do
  let some scoutDir := s.scoutDir | throw "No scout directory specified (use --scoutDir)"
  let some command := s.command | throw "No command specified (use --command)"
  let some targetSpec := s.targetSpec | throw "No target specified (use --imports, --library, or --read)"
  let some writerSpec := s.writerSpec | throw "No writer specified (use --parquet or --jsonl)"
  let cmdRoot := s.cmdRoot.getD <| .mk "."
  -- Resolve dataDir relative to cmdRoot
  let dataDir := resolvePath cmdRoot <| s.dataDir.getD <| .mk "./data"
  -- Resolve read paths relative to cmdRoot
  let targetSpec := match targetSpec with
    | .read paths => .read <| paths.map (resolvePath cmdRoot)
    | other => other
  return {
    scoutDir, cmdRoot, command, targetSpec, writerSpec, dataDir,
    numShards := s.numShards.getD 128,
    batchRows := s.batchRows.getD 1024,
    parallel := s.parallel.getD 1
  }

def parseArgs (args : List String) : Except String Config := go args {}
where
  go : List String → ArgState → Except String Config
    | "--parallel" :: nStr :: rest, s => do
      let some n := nStr.toNat? | throw s!"Invalid value for --parallel: '{nStr}'"
      go rest { s with parallel := some n }
    | "--scoutDir" :: path :: rest, s => go rest { s with scoutDir := some <| .mk path }
    | "--cmdRoot" :: path :: rest, s => go rest { s with cmdRoot := some <| .mk path }
    | "--command" :: cmd :: rest, s => go rest { s with command := cmd.toName }
    | "--dataDir" :: path :: rest, s => go rest { s with dataDir := some <| .mk path }
    | "--numShards" :: nStr :: rest, s => do
      let some n := nStr.toNat? | throw s!"Invalid value for --numShards: '{nStr}'"
      go rest { s with numShards := some n }
    | "--batchRows" :: nStr :: rest, s => do
      let some n := nStr.toNat? | throw s!"Invalid value for --batchRows: '{nStr}'"
      go rest { s with batchRows := some n }
    | "--parquet" :: rest, s => do
      if s.writerSpec.isSome then throw "Cannot specify both --parquet and --jsonl"
      go rest { s with writerSpec := some .parquet }
    | "--jsonl" :: rest, s => do
      if s.writerSpec.isSome then throw "Cannot specify both --parquet and --jsonl"
      go rest { s with writerSpec := some .jsonl }
    | "--imports" :: importsList, s => do
      if s.targetSpec.isSome then throw "Cannot specify multiple targets (--imports, --library, or --read)"
      { s with targetSpec := some <| .imports importsList.toArray }.toConfig
    | "--read" :: paths@(_ :: _), s => do
      if s.targetSpec.isSome then throw "Cannot specify multiple targets (--imports, --library, or --read)"
      { s with targetSpec := some <| .read <| paths.map .mk }.toConfig
    | "--library" :: name :: rest, s => do
      if s.targetSpec.isSome then throw "Cannot specify multiple targets (--imports, --library, or --read)"
      go rest { s with targetSpec := some <| .library name.toName }
    | [], s => s.toConfig
    | unknown :: _, _ => throw s!"Unknown argument: '{unknown}'"

def TargetSpec.toTargets : TargetSpec → ExceptT String IO (Array Target)
  | .imports names => return #[.mkImports names]
  | .read paths => return paths.toArray.map fun p => .read p
  | .library name => do
    let output ← IO.Process.output {
      cmd := "lake"
      args := #["query", "-q", s!"{name}:module_paths"]
    }
    if output.exitCode != 0 then
      throw s!"lake query failed for library '{name}': {output.stderr.trim}"
    let lines := output.stdout.splitOn "\n" |>.filter (·.trim ≠ "")
    if lines.isEmpty then
      throw s!"No modules found for library '{name}'"
    return lines.toArray.map fun s => .read <| System.FilePath.mk s

structure Writer where
  wait : IO UInt32
  sink : String → IO Unit

-- unsafe because `data_extractors` elaborator runs in meta context
unsafe
def run (cfg : Config) : IO UInt32 := do
  let targets ← match ← cfg.targetSpec.toTargets.run with
    | .ok tgts => pure tgts
    | .error err => logError err ; return 1

  let extractorCfgs : Array Extractor.Config := targets.map fun tgt => ⟨cfg.command, tgt⟩

  let some extractor := (data_extractors).get? cfg.command
    | logError s!"No data extractor found for command '{cfg.command}'" ; return 1

  let writer : Std.Mutex Writer ← Std.Mutex.new <| ← match cfg.writerSpec with
  | .jsonl => jsonlWriter
  | .parquet => parquetWriter cfg extractor

  let mut launches : Array (String × IO (Task <| Except IO.Error UInt32)) := #[]
  for extractorCfg in extractorCfgs do
    let cfgArg := Lean.toJson extractorCfg |>.compress
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
      logInfo s!"Started extractor task {launchIdx} with config {cfgArg}"
      taskPool := taskPool.insert launchIdx (← task)
      launchIdx := launchIdx + 1

    -- Check for completed tasks
    for (idx, task) in taskPool do
      if ← IO.hasFinished task then
        let res ← IO.wait task
        match res with
        | .ok code => logInfo s!"Extractor task {idx} finished with exit code {code}"
        | .error err => logError s!"Extractor task {idx} failed with error: {err}"
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

parquetWriter (cfg : Config) (extractor : DataExtractor) : IO Writer := do
  IO.FS.createDirAll cfg.dataDir
  let dataDir ← IO.FS.realPath cfg.dataDir
  let subprocess ← IO.Process.spawn {
    cwd := cfg.scoutDir
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
  match parseArgs args with
  | .ok cfg => run cfg
  | .error err => logError err ; return 1
