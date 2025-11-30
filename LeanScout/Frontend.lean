module

public import LeanScout.Target

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

unsafe
def runParallelCoreM (tgt : ImportsTarget) (opts : Options)
    (go : Environment → Name → ConstantInfo → CoreM α) :
    IO (Array (Task <| Except IO.Error α)) := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withEnv opts fun env => do
    let ctx : Core.Context := {
        fileName := "<target>"
        fileMap := default
        initHeartbeats := initHeartbeats
        maxHeartbeats := maxHeartbeats.get opts
        options := opts }
    let state : Core.State := { env := env }
    let mut tasks : Array (Task <| Except IO.Error α) := #[]
    for (n,c) in env.constants do
      let task ← IO.asTask <| (go env n c |>.toIO ctx state) <&> Prod.fst
      tasks := tasks.push task
    return tasks

end ImportsTarget

end LeanScout
