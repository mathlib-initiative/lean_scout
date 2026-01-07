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

- `maxTasks`: Optional limit on concurrent tasks. `none` means unlimited (all tasks spawned immediately).
- `go`: The computation to run for each constant, receiving the environment, constant name, and constant info.

When `maxTasks` is `none`, spawns all tasks immediately without waiting (fire-and-forget).
When `maxTasks` is `some n`, uses a bounded task pool and waits for all tasks to complete.

This function uses `TaskPool.runForM_` internally, which iterates directly over `env.constants`
without pre-collecting them into an array, making it memory-efficient for large environments.
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

    let poolConfig : TaskPool.Config := { maxConcurrent := maxTasks }
    TaskPool.runForM_ env.constants (fun (n, c) => (go env n c |>.toIO ctx state) <&> Prod.fst) poolConfig

end ImportsTarget

end LeanScout
