import LeanScoutTest  -- Runs all #eval/#guard_msgs schema tests during elaboration

def main : IO UInt32 := do
  IO.println "Lean schema tests passed. Running full test suite..."
  let child ← IO.Process.spawn {
    cmd := "./run_tests"
  }
  child.wait
