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
  let (header, parserState, messages) ← Parser.parseHeader tgt.context
  let (env, messages) ← processHeader header tgt.opts messages tgt.context
  let commandState := { Command.mkState env messages tgt.opts with infoState.enabled := true }
  go.run { inputCtx := tgt.context } |>.run' { commandState, parserState, cmdPos := parserState.pos }

unsafe
def withFinalCommandState (tgt : InputTarget)
    (go : Command.State → IO α) : IO α :=
  tgt.runFrontend do processCommands ; go (← get).commandState

unsafe
def withFinalInfoState (tgt : InputTarget) (go : InfoState → IO α) : IO α :=
  tgt.withFinalCommandState fun s => go s.infoState

unsafe
def withInfoTrees (tgt : InputTarget) (go : PersistentArray InfoTree → IO α) : IO α :=
  tgt.withFinalInfoState fun s => go s.trees

unsafe
def withVisitM (tgt : InputTarget)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (PersistentArray (Option α)) := do
  tgt.withInfoTrees fun trees => trees.mapM fun tree => tree.visitM preNode postNode ctx?

/-
unsafe
def withEnv (tgt : InputTarget) (go : Environment → IO α) : IO α :=
  tgt.withFinalCommandState fun s => go s.env

unsafe
def runCoreM (tgt : InputTarget) (go : CoreM α) : IO α := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withFinalCommandState fun s => Prod.fst <$> go.toIO
    { fileName := tgt.context.fileName,
      fileMap := default
      initHeartbeats := initHeartbeats
      maxHeartbeats := maxHeartbeats.get tgt.opts
      options := tgt.opts }
    { env := s.env }

unsafe
def runParallelCoreM (tgt : InputTarget) (go : Environment → Name → ConstantInfo → CoreM α) :
    IO (Array (Task <| Except IO.Error α)) := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withFinalCommandState fun s => do
    let ctx : Core.Context := {
        fileName := tgt.context.fileName
        fileMap := default
        initHeartbeats := initHeartbeats
        maxHeartbeats := maxHeartbeats.get tgt.opts
        options := tgt.opts }
    let state : Core.State := { env := s.env }
    let mut tasks : Array (Task <| Except IO.Error α) := #[]
    for (n,c) in s.env.constants do
      let task ← IO.asTask <| (go s.env n c |>.toIO ctx state) <&> Prod.fst
      tasks := tasks.push task
    return tasks
-/

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
