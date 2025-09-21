module

public import LeanScout
public meta import LeanScout.DataExtractors

namespace LeanScout

open Lean

abbrev Command := String

structure Options where
  command : Command
  outPath : System.FilePath
  target : Target

abbrev M := ReaderT Options IO

def getCommand : M Command := read <&> Options.command
def getTarget : M Target := read <&> Options.target
def getOutPath : M (System.FilePath) := read <&> Options.outPath

def run (args : List String) (go : M α) : IO α := do
  match args with
  | cmd :: outPath :: "imports" :: args => go (.mk cmd outPath <| .mkImports args)
  | cmd :: outPath :: "read" :: path :: [] => go (.mk cmd outPath <| ← Target.read path)
  | _ => throw <| .userError "Usage: scout <COMMAND> [args]"

meta unsafe
def main : M Unit := do
  let command ← getCommand
  let dataExtractors := (data_extractors).filter fun e => e.command == command
  let basePath : System.FilePath := "data" / command
  let filePath := basePath / (← getOutPath) |>.normalize
  if let some fileDir := filePath.parent then IO.FS.createDirAll fileDir
  let handle ← IO.FS.Handle.mk (basePath / (← getOutPath)) .write
  let tgt ← getTarget
  for extractor in dataExtractors do extractor.go handle tgt

end LeanScout

open LeanScout

public meta unsafe def main (args : List String) := do
  LeanScout.run args LeanScout.main
