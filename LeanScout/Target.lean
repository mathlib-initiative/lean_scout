module

public import LeanScout.Types

public section

namespace LeanScout

open Lean Elab Frontend

def InputTarget.inputCtx (tgt : InputTarget) : IO Parser.InputContext :=
  return Parser.mkInputContext (← IO.FS.readFile tgt.path) "<target>"

def Target.toString : Target → String
  | .imports ⟨_, i⟩ => s!"imports {i}"
  | .input ⟨_, i⟩ => s!"input {i}"

def Target.read (path : System.FilePath) (opts : Options) : Target :=
  .input <| ⟨.mk opts, path⟩

def Target.mkImports (imports : Array String) (opts : Options) : Target :=
  .imports ⟨.mk opts, imports.map fun s => {
    module := s.toName
    importAll := true
    isExported := false
    isMeta := true
  }⟩

end LeanScout
