module

public import Std
public import Init.System.IO

public section

namespace LeanScout

/-- Configuration for a task pool with optional parallelism limit -/
structure TaskPool.Config where
  /-- Maximum concurrent tasks. `none` means unlimited (all tasks spawned immediately). -/
  maxConcurrent : Option Nat := none
  /-- If true, stop spawning new tasks after the first error. Already-running tasks will complete. -/
  failFast : Bool := false
  /-- Polling interval in milliseconds when waiting for task completion. -/
  pollIntervalMs : UInt32 := 1

/-- Callbacks for task lifecycle events -/
structure TaskPool.Callbacks (β : Type) (α : Type) where
  /-- Called when a task is about to be spawned. Receives the index and input item. -/
  onStart : Nat → β → IO Unit := fun _ _ => pure ()
  /-- Called when a task completes. Receives the index, input item, and result. -/
  onComplete : Nat → β → Except IO.Error α → IO Unit := fun _ _ _ => pure ()

/--
Run tasks with bounded parallelism, collecting all results.

- `items`: Array of inputs to process
- `spawn`: Function that creates an `IO α` computation from an input (will be wrapped in a Task)
- `config`: Pool configuration (max concurrency, fail-fast behavior, poll interval)
- `callbacks`: Optional callbacks for task start/complete events

Returns array of results in the same order as inputs.
-/
def TaskPool.run [Inhabited β] (items : Array β)
    (spawn : β → IO α)
    (config : TaskPool.Config := {})
    (callbacks : TaskPool.Callbacks β α := {}) : IO (Array (Except IO.Error α)) := do

  match config.maxConcurrent with
  | none => runUnlimited items spawn callbacks
  | some 0 => runUnlimited items spawn callbacks  -- treat 0 as unlimited
  | some limit => runLimited items spawn limit config.failFast config.pollIntervalMs callbacks

where
  /-- Unlimited mode: spawn all tasks immediately, then wait for all results -/
  runUnlimited (items : Array β) (spawn : β → IO α)
      (callbacks : TaskPool.Callbacks β α) : IO (Array (Except IO.Error α)) := do
    -- Spawn all tasks
    let mut tasks : Array (Task (Except IO.Error α)) := #[]
    for idx in [0:items.size] do
      let item := items[idx]!
      callbacks.onStart idx item
      let task ← IO.asTask (spawn item)
      tasks := tasks.push task

    -- Wait for all and collect results
    let mut results : Array (Except IO.Error α) := #[]
    for idx in [0:tasks.size] do
      let task := tasks[idx]!
      let result ← IO.wait task
      let item := items[idx]!
      callbacks.onComplete idx item result
      results := results.push result
    return results

  /-- Limited mode: maintain a pool of at most `limit` concurrent tasks -/
  runLimited (items : Array β) (spawn : β → IO α) (limit : Nat)
      (failFast : Bool) (pollIntervalMs : UInt32)
      (callbacks : TaskPool.Callbacks β α) : IO (Array (Except IO.Error α)) := do
    -- Track active tasks by their original index
    let mut activePool : Std.HashMap Nat (Task (Except IO.Error α)) := {}
    let mut launchIdx := 0
    let mut results : Std.HashMap Nat (Except IO.Error α) := {}
    let mut hasError := false

    while launchIdx < items.size || !activePool.isEmpty do
      -- Launch new tasks up to the limit (unless we're in fail-fast mode with an error)
      while activePool.size < limit && launchIdx < items.size && !(failFast && hasError) do
        let item := items[launchIdx]!
        callbacks.onStart launchIdx item
        let task ← IO.asTask (spawn item)
        activePool := activePool.insert launchIdx task
        launchIdx := launchIdx + 1

      -- Check for completed tasks
      for (idx, task) in activePool do
        if ← IO.hasFinished task then
          let result ← IO.wait task
          let item := items[idx]!
          callbacks.onComplete idx item result
          results := results.insert idx result
          activePool := activePool.erase idx
          if let .error _ := result then
            hasError := true

      -- Small sleep to avoid busy-waiting (only if we have active tasks)
      if !activePool.isEmpty then
        IO.sleep pollIntervalMs

    -- Convert results map to ordered array
    let mut orderedResults : Array (Except IO.Error α) := #[]
    for idx in [0:items.size] do
      match results[idx]? with
      | some r => orderedResults := orderedResults.push r
      | none => orderedResults := orderedResults.push (.error <| IO.userError s!"Missing result for index {idx}")
    return orderedResults

/--
Run tasks with bounded parallelism, discarding results.
Convenience wrapper when results are not needed.
-/
def TaskPool.run_ [Inhabited β] (items : Array β)
    (spawn : β → IO α)
    (config : TaskPool.Config := {})
    (callbacks : TaskPool.Callbacks β α := {}) : IO Unit := do
  discard <| TaskPool.run items spawn config callbacks

/--
Run deferred tasks with bounded parallelism, collecting all results.

This variant accepts task creators that return `IO (Task ...)` instead of `IO α`.
This is useful when the task creation itself has side effects that should be deferred
(e.g., spawning subprocesses).

- `items`: Array of inputs to process
- `spawnTask`: Function that creates and spawns a Task from an input
- `config`: Pool configuration (max concurrency, fail-fast behavior, poll interval)
- `callbacks`: Optional callbacks for task start/complete events

Returns array of results in the same order as inputs.
-/
def TaskPool.runDeferred [Inhabited β] (items : Array β)
    (spawnTask : β → IO (Task (Except IO.Error α)))
    (config : TaskPool.Config := {})
    (callbacks : TaskPool.Callbacks β α := {}) : IO (Array (Except IO.Error α)) := do

  match config.maxConcurrent with
  | none => runUnlimited items spawnTask callbacks
  | some 0 => runUnlimited items spawnTask callbacks  -- treat 0 as unlimited
  | some limit => runLimited items spawnTask limit config.failFast config.pollIntervalMs callbacks

where
  /-- Unlimited mode: spawn all tasks immediately, then wait for all results -/
  runUnlimited (items : Array β) (spawnTask : β → IO (Task (Except IO.Error α)))
      (callbacks : TaskPool.Callbacks β α) : IO (Array (Except IO.Error α)) := do
    -- Spawn all tasks
    let mut tasks : Array (Task (Except IO.Error α)) := #[]
    for idx in [0:items.size] do
      let item := items[idx]!
      callbacks.onStart idx item
      let task ← spawnTask item
      tasks := tasks.push task

    -- Wait for all and collect results
    let mut results : Array (Except IO.Error α) := #[]
    for idx in [0:tasks.size] do
      let task := tasks[idx]!
      let result ← IO.wait task
      let item := items[idx]!
      callbacks.onComplete idx item result
      results := results.push result
    return results

  /-- Limited mode: maintain a pool of at most `limit` concurrent tasks -/
  runLimited (items : Array β) (spawnTask : β → IO (Task (Except IO.Error α))) (limit : Nat)
      (failFast : Bool) (pollIntervalMs : UInt32)
      (callbacks : TaskPool.Callbacks β α) : IO (Array (Except IO.Error α)) := do
    -- Track active tasks by their original index
    let mut activePool : Std.HashMap Nat (Task (Except IO.Error α)) := {}
    let mut launchIdx := 0
    let mut results : Std.HashMap Nat (Except IO.Error α) := {}
    let mut hasError := false

    while launchIdx < items.size || !activePool.isEmpty do
      -- Launch new tasks up to the limit (unless we're in fail-fast mode with an error)
      while activePool.size < limit && launchIdx < items.size && !(failFast && hasError) do
        let item := items[launchIdx]!
        callbacks.onStart launchIdx item
        let task ← spawnTask item
        activePool := activePool.insert launchIdx task
        launchIdx := launchIdx + 1

      -- Check for completed tasks
      for (idx, task) in activePool do
        if ← IO.hasFinished task then
          let result ← IO.wait task
          let item := items[idx]!
          callbacks.onComplete idx item result
          results := results.insert idx result
          activePool := activePool.erase idx
          if let .error _ := result then
            hasError := true

      -- Small sleep to avoid busy-waiting (only if we have active tasks)
      if !activePool.isEmpty then
        IO.sleep pollIntervalMs

    -- Convert results map to ordered array
    let mut orderedResults : Array (Except IO.Error α) := #[]
    for idx in [0:items.size] do
      match results[idx]? with
      | some r => orderedResults := orderedResults.push r
      | none => orderedResults := orderedResults.push (.error <| IO.userError s!"Missing result for index {idx}")
    return orderedResults

end LeanScout
