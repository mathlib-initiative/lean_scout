module

public import LeanScout.Types

namespace LeanScout

public def logger : Logger where
  log s msg := do
    let t ← Std.Time.DateTime.now (tz := Std.Time.TimeZone.GMT)
    let stderr ← IO.getStderr
    stderr.putStrLn s!"{t} [{s}] {msg}"
    stderr.flush

end LeanScout
