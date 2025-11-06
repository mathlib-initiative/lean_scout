module

public import LeanScout.Target

public section

namespace LeanScout

open Lean Elab Frontend

namespace InputTarget

unsafe
def runFrontend (tgt : InputTarget) (go : FrontendM α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let (header, parserState, messages) ← Parser.parseHeader <| ← tgt.inputCtx
  let (env, messages) ← processHeader header tgt.opts messages <| ← tgt.inputCtx
  let commandState := { Command.mkState env messages tgt.opts with infoState.enabled := true }
  go.run { inputCtx := ← tgt.inputCtx } |>.run' { commandState, parserState, cmdPos := parserState.pos }

unsafe
def withFinalCommandState (tgt : InputTarget)
    (go : Command.State → IO α) : IO α :=
  tgt.runFrontend do processCommands ; go (← get).commandState

unsafe
def withFinalInfoState (tgt : InputTarget) (go : InfoState → IO α) : IO α :=
  tgt.withFinalCommandState fun s => go s.infoState

unsafe
def withInfoTrees (tgt : InputTarget) (go : InfoTree → IO α) : IO (Array α) :=
  tgt.runFrontend do
    let mut done := false
    let mut out := #[]
    while !done do
      done ← processCommand
      if let some lastInfoTree := (← get).commandState.infoState.trees.toArray.back? then
        let res ← go lastInfoTree
        out := out.push res
    return out

unsafe
def withVisitM (tgt : InputTarget)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (Array (Option α)) := do
  tgt.withInfoTrees fun tree => tree.visitM preNode postNode ctx?

end InputTarget

namespace ImportsTarget

unsafe
def withEnv (tgt : ImportsTarget) (go : Environment → IO α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let env ← Lean.importModules tgt.imports tgt.opts
  go env

unsafe
def runCoreM (tgt : ImportsTarget) (go : CoreM α) : IO α := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withEnv fun env => do
    let ctx : Core.Context := {
        fileName := "<target>"
        fileMap := default
        initHeartbeats := initHeartbeats
        maxHeartbeats := maxHeartbeats.get tgt.opts
        options := tgt.opts }
    let state : Core.State := { env := env }
    Prod.fst <$> go.toIO ctx state

unsafe
def runParallelCoreM (tgt : ImportsTarget) (go : Environment → Name → ConstantInfo → CoreM α) :
    IO (Array (Task <| Except IO.Error α)) := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withEnv fun env => do
    let ctx : Core.Context := {
        fileName := "<target>"
        fileMap := default
        initHeartbeats := initHeartbeats
        maxHeartbeats := maxHeartbeats.get tgt.opts
        options := tgt.opts }
    let state : Core.State := { env := env }
    let mut tasks : Array (Task <| Except IO.Error α) := #[]
    for (n,c) in env.constants do
      let task ← IO.asTask <| (go env n c |>.toIO ctx state) <&> Prod.fst
      tasks := tasks.push task
    return tasks

end ImportsTarget

end LeanScout
