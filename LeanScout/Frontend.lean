module

public import LeanScout.Target

public section

namespace LeanScout
namespace Target

open Lean Elab Frontend

unsafe
def runFrontend (tgt : Target) (go : FrontendM α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let inputCtx := Parser.mkInputContext tgt.src tgt.fileName
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let (env, messages) ← processHeader header tgt.opts messages inputCtx
  let commandState := { Command.mkState env messages tgt.opts with infoState.enabled := true }
  go.run { inputCtx } |>.run' { commandState, parserState, cmdPos := parserState.pos }

unsafe
def withFinalCommandState (tgt : Target) (go : Command.State → IO α) : IO α :=
  tgt.runFrontend do processCommands ; go (← get).commandState

unsafe
def withFinalInfoState (tgt : Target) (go : InfoState → IO α) : IO α :=
  tgt.withFinalCommandState fun s => go s.infoState

unsafe
def withInfoTrees (tgt : Target) (go : PersistentArray InfoTree → IO α) : IO α :=
  tgt.withFinalInfoState fun s => go s.trees

unsafe
def withVisitM (tgt : Target)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (PersistentArray (Option α)) := do
  tgt.withInfoTrees fun trees => trees.mapM fun tree => tree.visitM preNode postNode ctx?

unsafe
def withEnv (tgt : Target) (go : Environment → IO α) : IO α :=
  tgt.withFinalCommandState fun s => go s.env

unsafe
def runCoreM (tgt : Target) (go : CoreM α) : IO α := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withFinalCommandState fun s => Prod.fst <$> go.toIO
    { fileName := tgt.fileName,
      fileMap := default
      initHeartbeats := initHeartbeats
      maxHeartbeats := maxHeartbeats.get tgt.opts
      options := tgt.opts }
    { env := s.env }

unsafe
def runParallelCoreM (tgt : Target) (go : Environment → Name → ConstantInfo → CoreM α) :
    IO (Array (Task <| Except IO.Error α)) := do
  let initHeartbeats ← IO.getNumHeartbeats
  tgt.withFinalCommandState fun s => do
    let ctx : Core.Context := {
        fileName := tgt.fileName,
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

end Target

end LeanScout
