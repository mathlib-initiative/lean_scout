module

public import LeanScout
public meta import LeanScout.DataExtractors

namespace LeanScout

open Lean

abbrev Command := String

structure Options where
  scoutPath : System.FilePath
  command : Command
  dataDir : System.FilePath
  target : Target

abbrev M := ReaderT Options IO

def getCommand : M Command := read <&> Options.command
def getTarget : M Target := read <&> Options.target
def getDataDir : M System.FilePath := read <&> Options.dataDir
def getScoutPath : M System.FilePath := read <&> Options.scoutPath

def run (args : List String) (go : M α) : IO α := do
  match args with
  | scoutPath :: cmd :: dataDir :: "imports" :: args => go (.mk scoutPath cmd dataDir <| .mkImports args)
  | scoutPath :: cmd :: dataDir :: "read" :: path :: [] => go (.mk scoutPath cmd dataDir <| ← Target.read path)
  | _ => throw <| .userError "Usage: scout <COMMAND> [args]"

meta unsafe
def main : M Unit := do
  let command ← getCommand
  let dataExtractors := (data_extractors).filter fun e => e.command == command
  let basePath : System.FilePath := (← getDataDir) / command |>.normalize
  IO.FS.createDirAll basePath
  let realPath ← IO.FS.realPath basePath
  let tgt ← getTarget
  for extractor in dataExtractors do
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
    let (stdin, _) ← compressor.takeStdin
    extractor.go stdin tgt

end LeanScout

open LeanScout

public meta unsafe def main (args : List String) := do
  LeanScout.run args LeanScout.main
