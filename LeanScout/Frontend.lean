module

public import LeanScout.Target
public import LeanScout.TaskPool

public section

namespace LeanScout

open Lean Elab Frontend

namespace InputTarget

unsafe
def processCommands (tgt : InputTarget) (opts : Options) (go : State → IO α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let (header, parserState, messages) ← Parser.parseHeader <| ← tgt.inputCtx
  let (env, messages) ← processHeader header opts messages <| ← tgt.inputCtx
  let commandState := { Command.mkState env messages opts with infoState.enabled := true }
  let s ← IO.processCommands (← tgt.inputCtx) parserState commandState
  go s

unsafe
def withInfoTrees (tgt : InputTarget) (opts : Options) (go : InfoTree → IO α) : IO (PersistentArray α) :=
  tgt.processCommands opts fun s => s.commandState.infoState.trees.mapM go

unsafe
def withVisitM
    (tgt : InputTarget) (opts : Options)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (PersistentArray (Option α)) := do
  tgt.withInfoTrees opts fun tree => tree.visitM preNode postNode ctx?

end InputTarget

namespace ImportsTarget

unsafe
def withEnv (tgt : ImportsTarget) (opts : Options) (go : Environment → IO α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let env ← Lean.importModules (loadExts := true) tgt.imports opts
  go env

unsafe
def runCoreM (tgt : ImportsTarget) (opts : Options) (go : CoreM α) : IO α := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withEnv opts fun env => do
    let ctx : Core.Context := {
        fileName := "<target>"
        fileMap := default
        initHeartbeats := initHeartbeats
        maxHeartbeats := maxHeartbeats.get opts
        options := opts }
    let state : Core.State := { env := env }
    Prod.fst <$> go.toIO ctx state

/--
Run a `CoreM` computation in parallel for each constant in the environment.

- `maxTasks`: Optional limit on concurrent tasks. `none` means unlimited (all tasks spawned immediately
  and the function returns without waiting for completion - fire-and-forget mode).
- `go`: The computation to run for each constant, receiving the environment, constant name, and constant info.

When `maxTasks` is `none`, spawns all tasks immediately and returns without waiting (original behavior).
When `maxTasks` is `some n`, uses a bounded task pool and waits for all tasks to complete.
-/
unsafe
def runParallelCoreM (tgt : ImportsTarget) (opts : Options)
    (go : Environment → Name → ConstantInfo → CoreM α)
    (maxTasks : Option Nat := none) :
    IO Unit := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withEnv opts fun env => do
    let ctx : Core.Context := {
        fileName := "<target>"
        fileMap := default
        initHeartbeats := initHeartbeats
        maxHeartbeats := maxHeartbeats.get opts
        options := opts }
    let state : Core.State := { env := env }

    match maxTasks with
    | none =>
      -- Unlimited mode: spawn all tasks immediately, don't wait (fire-and-forget)
      for (n, c) in env.constants do
        discard <| IO.asTask <| (go env n c |>.toIO ctx state) <&> Prod.fst
    | some limit =>
      -- Limited mode: bound concurrency using an inline task pool
      -- We avoid pre-collecting all constants to prevent stack overflow on large environments
      let mut activePool : Std.HashMap Nat (Task (Except IO.Error α)) := {}
      let mut idx := 0
      for (n, c) in env.constants do
        -- Wait until we have room in the pool
        while activePool.size >= limit do
          for (taskIdx, task) in activePool do
            if ← IO.hasFinished task then
              activePool := activePool.erase taskIdx
          if activePool.size >= limit then
            IO.sleep 1

        -- Spawn new task
        let task ← IO.asTask <| (go env n c |>.toIO ctx state) <&> Prod.fst
        activePool := activePool.insert idx task
        idx := idx + 1

      -- Wait for remaining tasks to complete
      while !activePool.isEmpty do
        for (taskIdx, task) in activePool do
          if ← IO.hasFinished task then
            activePool := activePool.erase taskIdx
        if !activePool.isEmpty then
          IO.sleep 1

end ImportsTarget

end LeanScout
