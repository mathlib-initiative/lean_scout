module

public import LeanScout.DataExtractors
public import LeanScout.Logger
public import LeanScout.Frontend

namespace LeanScout

open Lean Elab Frontend

namespace Extractor
public structure Config where
  command : Command
  target : Target
  extractorConfig : Json := Json.mkObj []
  plugins : Array Name := #[]
deriving ToJson, FromJson

/-- Load data extractors from plugin modules.

This function imports the specified plugin modules and extracts any
`DataExtractor` definitions that have been tagged with `@[data_extractor cmd]`.
Returns an empty HashMap if no plugins are specified.
-/
unsafe def loadPluginExtractors (plugins : Array Name) : IO (Std.HashMap Command DataExtractor) := do
  if plugins.isEmpty then return {}
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let imports := plugins.map fun name => {
    module := name
    importAll := true
    isExported := false
    isMeta := true : Import
  }
  let env ← Lean.importModules (loadExts := true) imports {}
  loadExtractorsFromEnv env

public unsafe
def extract (cfg : Config): IO UInt32 := do
  -- Load plugin extractors and merge with built-in extractors (plugins take priority)
  let pluginExtractors ← loadPluginExtractors cfg.plugins
  -- Start with plugin extractors, then insert built-ins only if not already present
  let mut allExtractors := pluginExtractors
  for (cmd, ext) in (data_extractors) do
    if !allExtractors.contains cmd then
      allExtractors := allExtractors.insert cmd ext

  let some extractor := allExtractors.get? cfg.command
    | logger.log .error s!"Failed to find extractor {cfg.command}" ; return 1
  let stdout ← IO.getStdout
  let sink (j : Json) : IO Unit := do
    stdout.putStrLn j.compress
    stdout.flush
  extractor.go cfg.extractorConfig sink {} cfg.target
  return 0

end Extractor

end LeanScout
