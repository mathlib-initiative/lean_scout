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
  extractorConfig : Json
  plugins : Array Name

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
  extractorConfig : Option Json := none
  plugins : Array String := #[]

private def helpText : String :=
  "Lean Scout - extract datasets from Lean projects.

USAGE:
  lake run scout --command <command> (--parquet | --jsonl) <target> [options]

TARGETS:
  --imports <module...>   Extract from imported modules (single subprocess).
  --read <paths...>       Extract from specific files (one subprocess per path).
  --library <name>        Extract from all modules in a library (via lake query).

OPTIONS:
  --command <command>     Data extractor command name (e.g. types, tactics, const_dep).
  --parquet               Write sharded parquet output to --dataDir.
  --jsonl                 Stream JSON lines to stdout (ignores --dataDir).
  --dataDir <dir>         Output directory (default: ./data).
  --numShards <n>         Number of output shards (default: 128).
  --batchRows <n>         Rows per batch before flush (default: 1024).
  --parallel <n>          Max concurrent extractor tasks (default: 1).
  --config <json>         JSON object forwarded to extractor (default: {}).
  --plugin <module>       Load extractor plugin module (repeatable).
  --cmdRoot <dir>         Resolve relative paths from this root (default: .).
  --scoutDir <dir>        Lean Scout package root (required; set by lake run scout).
  -h, --help              Show this help and exit.

NOTES:
  Exactly one of --parquet or --jsonl is required.
  Exactly one target flag is required: --imports, --read, or --library.
  --imports and --read consume all remaining arguments.
  Place other flags before the target flag.
  Relative --read paths and --dataDir are resolved against --cmdRoot.
  Logging goes to stderr; --jsonl output goes to stdout.
"

private def printHelp : IO Unit := do
  let stdout ← IO.getStdout
  stdout.putStr helpText
  stdout.flush

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
    parallel := s.parallel.getD 1,
    extractorConfig := s.extractorConfig.getD <| Json.mkObj [],
    plugins := s.plugins.map String.toName
  }

def parseArgs (args : List String) : Except String Config := go args {}
where
  go : List String → ArgState → Except String Config
    | "--help" :: _, _ => throw helpText
    | "-h" :: _, _ => throw helpText
    | "--parallel" :: nStr :: rest, s => do
      let some n := nStr.toNat? | throw s!"Invalid value for --parallel: '{nStr}'"
      go rest { s with parallel := some n }
    | "--config" :: jsonStr :: rest, s => do
      let .ok json := Json.parse jsonStr | throw s!"Invalid JSON for --config: '{jsonStr}'"
      go rest { s with extractorConfig := some json }
    | "--plugin" :: pluginName :: rest, s =>
      go rest { s with plugins := s.plugins.push pluginName }
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

private structure LibraryModuleData where
  name : Name
  path : System.FilePath
  setupFile : System.FilePath
deriving FromJson

def TargetSpec.toTargets : TargetSpec → ExceptT String IO (Array Target)
  | .imports names => return #[.mkImports names]
  | .read paths => return paths.toArray.map fun p => .read p
  | .library name => do
    let output ← IO.Process.output {
      cmd := "lake"
      args := #["query", "--json", s!"{name}:moduleData"]
    }
    if output.exitCode != 0 then
      throw s!"lake query failed for library '{name}': {output.stderr.trimAscii}"
    let .ok json := Lean.Json.parse output.stdout
      | throw s!"Failed to parse lake query JSON for library '{name}'"
    let .ok modules := Lean.fromJson? (α := Array LibraryModuleData) json
      | throw s!"Failed to decode lake query result for library '{name}'"
    if modules.isEmpty then
      throw s!"No modules found for library '{name}'"
    return modules.map fun m => .read m.path (some m.setupFile)

structure Writer where
  finish : IO UInt32
  sink : String → IO Unit

private def taskFailed : Except IO.Error UInt32 → Bool
  | .ok code => code != 0
  | .error _ => true

private def logTaskResult (idx : Nat) (result : Except IO.Error UInt32) : IO Unit :=
  match result with
  | .ok code =>
      logInfo s!"Extractor task {idx} finished with exit code {code}"
  | .error err =>
      logError s!"Extractor task {idx} failed with error: {err}"

private def ignoreErrors (action : IO Unit) : IO Unit := do
  try
    action
  catch _ =>
    pure ()

-- unsafe because `data_extractors` elaborator runs in meta context and we use loadPluginExtractors
unsafe
def run (cfg : Config) : IO UInt32 := do
  let targets ← match ← cfg.targetSpec.toTargets.run with
    | .ok tgts => pure tgts
    | .error err => logError err ; return 1

  let extractorCfgs : Array Extractor.Config := targets.map fun tgt =>
    { command := cfg.command, target := tgt, extractorConfig := cfg.extractorConfig, plugins := cfg.plugins }

  -- Load plugin extractors and merge with built-in extractors (plugins take priority)
  let pluginExtractors ← loadPluginExtractors cfg.plugins
  let mut allExtractors := pluginExtractors
  for (cmd, ext) in (data_extractors) do
    if !allExtractors.contains cmd then
      allExtractors := allExtractors.insert cmd ext

  let some extractor := allExtractors.get? cfg.command
    | logError s!"No data extractor found for command '{cfg.command}'" ; return 1

  let writer? ← match cfg.writerSpec with
  | .jsonl => jsonlWriter
  | .parquet => parquetWriter cfg extractor

  match writer? with
  | .ok writer => go writer extractorCfgs
  | .error e => logError e ; return 1

where

  go (writer : Writer) (extractorCfgs : Array Extractor.Config) : IO UInt32 := do
    logInfo s!"Starting data extraction with {extractorCfgs.size} extractor configurations"

    let writer : Std.Mutex Writer ← Std.Mutex.new writer
    let launches : Array String := extractorCfgs.map fun extractorCfg =>
      Lean.toJson extractorCfg |>.compress

    logInfo s!"Launching {launches.size} extractor tasks"

    let launchExtractor (idx : Nat) (cfgArg : String) : IO RunningSubprocess := do
      logInfo s!"Started extractor task {idx} with config {cfgArg}"
      let args : Array String := #["exe", "-q", "lean_scout_extractor", cfgArg]
      subprocessLines "lake" args fun s =>
        writer.atomically do
          let w ← get
          w.sink s

    let cancelRunning (running : Std.HashMap Nat (String × RunningSubprocess)) : IO Unit := do
      for (_, (_, subprocess)) in running do
        ignoreErrors subprocess.cancel

    let mut active : Std.HashMap Nat (String × RunningSubprocess) := {}
    let mut nextIdx := 0
    let mut hasFailure := false

    while (!hasFailure && nextIdx < launches.size) || !active.isEmpty do
      while !hasFailure && nextIdx < launches.size && (cfg.parallel == 0 || active.size < cfg.parallel) do
        let idx := nextIdx
        let cfgArg := launches[idx]!
        try
          let subprocess ← launchExtractor idx cfgArg
          active := active.insert idx (cfgArg, subprocess)
          nextIdx := nextIdx + 1
        catch err =>
          logError s!"Failed to start extractor task {idx}: {err}"
          hasFailure := true
          nextIdx := nextIdx + 1
          cancelRunning active

      let mut completedAny := false
      let activeSnapshot := active
      for (idx, (cfgArg, subprocess)) in activeSnapshot do
        if ← IO.hasFinished subprocess.task then
          completedAny := true
          let result ← subprocess.wait
          let _ := cfgArg
          logTaskResult idx result
          active := active.erase idx
          if taskFailed result && !hasFailure then
            hasFailure := true
            cancelRunning active

      if !active.isEmpty && !completedAny then
        IO.sleep 10

    let writerResult : Except IO.Error UInt32 ← try
      Except.ok <$> writer.atomically do
        let w ← get
        w.finish
    catch err =>
      pure (Except.error err)

    match writerResult with
    | .ok code =>
        if code != 0 then
          logError s!"Writer exited with code {code}"
          hasFailure := true
    | .error err =>
        logError s!"Writer failed with error: {err}"
        hasFailure := true

    if hasFailure then
      return 1

    return 0

  jsonlWriter : ExceptT String IO Writer := return {
    finish := return 0
    sink := fun s => do
      let stdout ← IO.getStdout
      stdout.putStrLn s
      stdout.flush
  }

  parquetWriter (cfg : Config) (extractor : DataExtractor) : ExceptT String IO Writer := do
    if ← cfg.dataDir.pathExists then
      let entries ← cfg.dataDir.readDir
      unless entries.isEmpty do
        throw <| s!"Output directory '{cfg.dataDir}' already exists and is not empty"
    logInfo s!"Creating output directory '{cfg.dataDir}'"
    IO.FS.createDirAll cfg.dataDir

    let dataDir ← IO.FS.realPath cfg.dataDir

    let subprocess ← try
      IO.Process.spawn {
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
    catch err =>
      throw s!"Failed to start parquet writer: {err}"

    let (stdin, child) ← subprocess.takeStdin
    let stdinRef ← IO.mkRef (some stdin)
    return {
      finish := do
        stdinRef.set none
        child.wait
      sink := fun s => do
        match ← stdinRef.get with
        | some h =>
            h.putStrLn s
            h.flush
        | none =>
            throw <| IO.userError "Parquet writer stdin is already closed"
    }

end Orchestrator

end LeanScout

open LeanScout Orchestrator in
public unsafe def main (args : List String) : IO UInt32 := do
  match parseArgs args with
  | .ok cfg =>
      try
        run cfg
      catch err =>
        logError s!"Unhandled orchestrator error: {err}"
        return (1 : UInt32)
  | .error err =>
      if err == helpText then
        printHelp
        return 0
      logError err
      return (1 : UInt32)
