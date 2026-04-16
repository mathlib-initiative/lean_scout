module

public import LeanScout.Types

public section

namespace LeanScout

open Lean Elab Frontend

private def mkInputCtx (path : System.FilePath) : IO Parser.InputContext :=
  return Parser.mkInputContext (← IO.FS.readFile path) path.toString

def InputTarget.inputCtx (tgt : InputTarget) : IO Parser.InputContext :=
  mkInputCtx tgt.path

def SetupTarget.inputCtx (tgt : SetupTarget) : IO Parser.InputContext :=
  mkInputCtx tgt.path

def Target.toString : Target → String
  | .imports ⟨i⟩ => s!"imports {i}"
  | .input tgt => s!"input {tgt.path}"
  | .setup tgt => s!"setup {tgt.path}"

def Target.read (path : System.FilePath) : Target :=
  .input <| ⟨path⟩

def Target.mkSetup (path setupFile : System.FilePath) : Target :=
  .setup <| ⟨path, setupFile⟩

def Target.mkImports (imports : Array String) : Target :=
  .imports ⟨imports.map fun s => {
    module := s.toName
    importAll := true
    isExported := false
    isMeta := true
  }⟩

end LeanScout
