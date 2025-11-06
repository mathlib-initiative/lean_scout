module

public import LeanScout

namespace LeanScout.CLI

open Lean

abbrev Command := String

structure Options where
  scoutPath : System.FilePath := "."
  target : Option Target := none
  dataDir : System.FilePath := "."
  command : Option Command := none
  batchRows : Nat := 1024
  numShards : Nat := 128

abbrev M := ReaderT Options IO

def getCommand : M Command := do
  match ← read <&> Options.command with
  | some cmd => return cmd
  | none => throw <| .userError "No command specified. Use --command"

def getTarget : M Target := do
  match ← read <&> Options.target with
  | some tgt => return tgt
  | none => throw <| .userError "No target specified. Use --imports or --read"

def getDataDir : M System.FilePath := read <&> Options.dataDir

def getScoutPath : M System.FilePath := read <&> Options.scoutPath

def getNumShards : M Nat := read <&> Options.numShards

def getBatchRows : M Nat := read <&> Options.batchRows

def processArgs (args : List String) (opts : Options) : Options :=
  match args with
  | "--scoutPath" :: path :: args => processArgs args { opts with scoutPath := path }
  | "--command" :: command :: args => processArgs args { opts with command := some command }
  | "--dataDir" :: dataDir :: args => processArgs args { opts with dataDir := dataDir }
  | "--numShards" :: n :: args => processArgs args { opts with numShards := n.toNat! }
  | "--batchRows" :: n :: args => processArgs args { opts with batchRows := n.toNat! }
  | "--read" :: [path] => { opts with target := some <| .read path {} }
  | "--imports" :: importsList => { opts with target := some <| .mkImports importsList.toArray {} }
  | _ => opts

def run (args : List String) (go : M α) : IO α := go <| processArgs args {}

unsafe
def main : M UInt32 := do
  let command ← getCommand
  let dataExtractors := data_extractors
  if command == "extractors" then
    for (e, _) in dataExtractors do
      println! e
    return 0
  let some extractor := dataExtractors.get? command.toName
    | throw <| .userError s!"Unknown command: {command}"
  let basePath : System.FilePath := (← getDataDir) / command |>.normalize
  if ← basePath.isDir then throw <| .userError s!"Data directory {basePath} already exists. Aborting."
  IO.FS.createDirAll basePath
  let realPath ← IO.FS.realPath basePath
  let tgt ← getTarget
  let compressor ← IO.Process.spawn {
    cmd := "uv"
    cwd := ← getScoutPath
    args := #["run", "python", "-m", "lean_scout",
      "--numShards", s!"{← getNumShards}",
      "--batchRows", s!"{← getBatchRows}",
      "--basePath", realPath.toString,
      "--key", extractor.key,
      "--schema", extractor.schema.toJson.compress,
    ]
    stdin := .piped
  }
  let (stdin, child) ← compressor.takeStdin
  extractor.go stdin tgt
  child.wait

end LeanScout.CLI

open LeanScout

public unsafe def main (args : List String) := do
  LeanScout.CLI.run args LeanScout.CLI.main
