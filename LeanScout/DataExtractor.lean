module

public import LeanScout.Frontend
public meta import Lean.Elab.Term

open Lean

namespace LeanScout

public meta structure DataExtractor where
  command : String
  go : IO.FS.Handle → Target → IO Unit

end LeanScout
