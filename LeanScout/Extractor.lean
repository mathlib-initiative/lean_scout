module

public import LeanScout.DataExtractors
public import LeanScout.Logger

namespace LeanScout

open Lean

namespace Extractor
public structure Config where
  command : Command
  target : Target
  extractorConfig : Json := Json.mkObj []
  plugins : Array Name := #[]
deriving ToJson, FromJson

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
  let stdoutMutex : Std.Mutex IO.FS.Stream ← Std.Mutex.new stdout
  let sink (j : Json) : IO Unit :=
    stdoutMutex.atomically do
      let handle ← get
      handle.putStrLn j.compress
      handle.flush
  extractor.go cfg.extractorConfig sink {} cfg.target
  return 0

end Extractor

end LeanScout
