module

public import LeanScout.Types

public section

namespace LeanScout

open Lean Elab Frontend

def InputTarget.inputCtx (tgt : InputTarget) : IO Parser.InputContext :=
  return Parser.mkInputContext (← IO.FS.readFile tgt.path) tgt.path.toString

def Target.toString : Target → String
  | .imports ⟨i⟩ => s!"imports {i}"
  | .input tgt => s!"input {tgt.path}"

def Target.read (path : System.FilePath) (setupFile? : Option System.FilePath := none) : Target :=
  .input <| ⟨path, setupFile?⟩

def Target.mkImports (imports : Array String) : Target :=
  .imports ⟨imports.map fun s => {
    module := s.toName
    importAll := true
    isExported := false
    isMeta := true
  }⟩

end LeanScout
