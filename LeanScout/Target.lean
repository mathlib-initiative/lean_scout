module

public import Lean

public section

namespace LeanScout

open Lean Elab Frontend

structure Target where
  src : String
  fileName : String := "<target>"
  opts : Lean.Options := {}

namespace Target

def mkImports
    (imports : List String)
    (opts : Lean.Options := {}) : Target where
  src := Id.run do
    let mut out := ""
    for m in imports do
      out := out ++ s!"import {m}\n"
    return out
  fileName := "<imports>"
  opts := opts

def read
    (path : System.FilePath)
    (fileName : String := "<target>")
    (opts : Lean.Options := {}) : IO Target :=
  return {
    src := ← IO.FS.readFile path
    fileName := fileName
    opts := opts
  }


end Target

end LeanScout
