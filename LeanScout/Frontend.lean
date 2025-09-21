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
def runCoreM (tgt : Target) (go : CoreM α) : IO α :=
  tgt.withFinalCommandState fun s => Prod.fst <$> go.toIO
    { fileName := tgt.fileName, fileMap := default }
    { env := s.env }

end Target

end LeanScout
