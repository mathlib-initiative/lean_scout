module

public import LeanScout.Types

namespace LeanScout

public def logger : Logger where
  log s msg := do
    let t ← Std.Time.DateTime.now (tz := Std.Time.TimeZone.GMT)
    let stderr ← IO.getStderr
    stderr.putStrLn s!"{t} [{s}] {msg}"
    stderr.flush

public def logError (s : α) [ToString α] := logger.log .error (toString s)
public def logInfo (s : α) [ToString α] := logger.log .info (toString s)
public def logDebug (s : α) [ToString α] := logger.log .debug (toString s)

end LeanScout
