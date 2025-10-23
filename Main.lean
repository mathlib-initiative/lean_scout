module

public import LeanScout
public meta import LeanScout.DataExtractors

namespace LeanScout.CLI

open Lean

abbrev Command := String

structure Options where
  scoutPath : Option System.FilePath := none
  command : Option Command := none
  dataDir : Option System.FilePath := none
  target : Option Target := none

abbrev M := ReaderT Options IO

def getCommand : M Command := do
  match ← read <&> Options.command with
  | some cmd => return cmd
  | none => throw <| .userError "No command specified. Use --command"

def getTarget : M Target := do
  match ← read <&> Options.target with
  | some tgt => return tgt
  | none => throw <| .userError "No target specified. Use --imports or --read"

def getDataDir : M System.FilePath := do
  match ← read <&> Options.dataDir with
  | some dir => return dir
  | none => throw <| .userError "No data directory specified. Use --dataDir"

def getScoutPath : M System.FilePath := do
  match ← read <&> Options.scoutPath with
  | some path => return path
  | none => throw <| .userError "No scout path specified. Use --scoutPath"

def processArgs (args : List String) (opts : Options) : Options :=
  match args with
  | "--scoutPath" :: path :: args => processArgs args { opts with scoutPath := some path }
  | "--command" :: command :: args => processArgs args { opts with command := some command }
  | "--dataDir" :: dataDir :: args => processArgs args { opts with dataDir := some dataDir }
  | "--read" :: [path] => { opts with target := some <| .read path {} }
  | "--imports" :: importsList => { opts with target := some <| .mkImports importsList.toArray {} }
  | _ => opts

def run (args : List String) (go : M α) : IO α := go <| processArgs args {}

meta unsafe
def main : M UInt32 := do
  let command ← getCommand
  let some extractor := (data_extractors).get? command.toName
    | throw <| .userError "Unknown command: {command}"
  let basePath : System.FilePath := (← getDataDir) / command |>.normalize
  if ← basePath.isDir then throw <| .userError s!"Data directory {basePath} already exists. Aborting."
  IO.FS.createDirAll basePath
  let realPath ← IO.FS.realPath basePath
  let tgt ← getTarget
  let compressor ← IO.Process.spawn {
    cmd := "uv"
    cwd := ← getScoutPath
    args := #["run", "main.py",
      "--basePath", realPath.toString,
      "--schema", extractor.schema.toJson.compress,
      "--key", extractor.key
    ]
    stdin := .piped
  }
  let (stdin, child) ← compressor.takeStdin
  extractor.go stdin tgt
  child.wait

end LeanScout.CLI

open LeanScout

public meta unsafe def main (args : List String) := do
  LeanScout.CLI.run args LeanScout.CLI.main
