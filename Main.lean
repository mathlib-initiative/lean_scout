module

public import LeanScout
public meta import LeanScout.DataExtractors

namespace LeanScout

open Lean

abbrev Command := String

structure Options where
  command : Command
  dataDir : System.FilePath
  outPath : String
  target : Target

abbrev M := ReaderT Options IO

def getCommand : M Command := read <&> Options.command
def getTarget : M Target := read <&> Options.target
def getOutPath : M String := read <&> Options.outPath
def getDataDir : M System.FilePath := read <&> Options.dataDir

def run (args : List String) (go : M α) : IO α := do
  match args with
  | cmd :: dataDir :: outPath :: "imports" :: args => go (.mk cmd dataDir outPath <| .mkImports args)
  | cmd :: dataDir :: outPath :: "read" :: path :: [] => go (.mk cmd dataDir outPath <| ← Target.read path)
  | _ => throw <| .userError "Usage: scout <COMMAND> [args]"

meta unsafe
def main : M Unit := do
  let command ← getCommand
  let dataExtractors := (data_extractors).filter fun e => e.command == command
  let basePath : System.FilePath := (← getDataDir) / command
  let filePath := basePath / (← getOutPath) |>.normalize
  if let some fileDir := filePath.parent then IO.FS.createDirAll fileDir
  let compressor ← IO.Process.spawn {
    cmd := "zstd"
    args := #["-o", s!"{basePath / (← getOutPath)}.zst"]
    stdin := .piped
  }
  let (stdin, _) ← compressor.takeStdin
  --let handle ← IO.FS.Handle.mk (basePath / (← getOutPath)) .write
  let tgt ← getTarget
  for extractor in dataExtractors do extractor.go stdin tgt

end LeanScout

open LeanScout

public meta unsafe def main (args : List String) := do
  LeanScout.run args LeanScout.main
