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
  context : InputContext

inductive Target where
  | imports (imports : ImportsTarget)
  | input (input : InputTarget)

def Target.read (path : System.FilePath) (opts : Options) : IO Target := do
  let src ← IO.FS.readFile path
  let ctx : Parser.InputContext := Parser.mkInputContext src "<target>"
  return .input <| ⟨.mk opts, ctx⟩

def Target.mkImports (imports : Array String) (opts : Options) : Target :=
  .imports ⟨.mk opts, imports.map fun s => {
    module := s.toName
    importAll := true
    isExported := false
    isMeta := true
  }⟩

end LeanScout
