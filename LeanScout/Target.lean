module

public import Lean

public section

namespace LeanScout

open Lean Elab Frontend

structure BaseTarget where
  opts : Options

structure ImportsTarget extends BaseTarget where
  imports : Array Import

open Parser in
structure InputTarget extends BaseTarget where
  path : System.FilePath

def InputTarget.inputCtx (tgt : InputTarget) : IO Parser.InputContext :=
  return Parser.mkInputContext (← IO.FS.readFile tgt.path) "<target>"

inductive Target where
  | imports (imports : ImportsTarget)
  | input (input : InputTarget)

def Target.toString : Target → String
  | .imports ⟨_, i⟩ => s!"imports {i}"
  | .input ⟨_, i⟩ => s!"input {i}"

abbrev Targets := Array Target

def Target.read (path : System.FilePath) (opts : Options) : Target :=
  .input <| ⟨.mk opts, path⟩

def Target.mkImports (imports : Array String) (opts : Options) : Target :=
  .imports ⟨.mk opts, imports.map fun s => {
    module := s.toName
    importAll := true
    isExported := false
    isMeta := true
  }⟩

def Targets.read (path : System.FilePath) (opts : Options) : IO Targets := do
  IO.FS.lines path >>= Array.mapM fun s => return Target.read (opts := opts) <| .mk s

end LeanScout
