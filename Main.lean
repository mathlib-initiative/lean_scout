module

public import Extractor

namespace LeanScout

namespace CLI

structure Config where
  command : Option Command := none
  imports : Option (Array Lean.Import)
  read : Option System.FilePath := none
  library : Option (Array System.FilePath) := none

end CLI

end LeanScout
