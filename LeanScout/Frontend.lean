module

public import LeanScout.Target
public import LeanScout.TaskPool

public section

namespace LeanScout

open Lean Elab Frontend

private unsafe def formatErrorMessages (messages : MessageLog) : IO String := do
  let mut rendered : List String := []
  for msg in messages.reportedPlusUnreported do
    if msg.severity matches .error then
      rendered := rendered.concat (← msg.toString)
  return "\n".intercalate rendered

private unsafe def throwIfMessagesHaveErrors
    (path : System.FilePath) (stage : String) (messages : MessageLog) : IO Unit := do
  if messages.hasErrors then
    let rendered := (← formatErrorMessages messages).trimAscii.toString
    let details := if rendered.isEmpty then "(Lean reported errors, but no messages were rendered)" else rendered
    throw <| IO.userError s!"Lean reported errors while {stage} '{path}':\n{details}"

private def applyCmdlineFrontendDefaults (opts : Options) : Options :=
  let opts := Lean.internal.cmdlineSnapshots.setIfNotSet opts true
  Elab.async.setIfNotSet opts true

private unsafe def collectCommandInfoTrees
    (snap : Language.Lean.CommandParsedSnapshot) (acc : Array InfoTree := #[]) : Array InfoTree :=
  let acc := match snap.elabSnap.infoTreeSnap.get.infoTree? with
    | some tree => acc.push tree
    | none => acc
  match snap.nextCmdSnap? with
  | some next => collectCommandInfoTrees next.get acc
  | none => acc

namespace InputTarget

unsafe def processCommands (tgt : InputTarget) (opts : Options) (go : State → IO α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let opts := applyCmdlineFrontendDefaults opts
  let inputCtx ← tgt.inputCtx
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  throwIfMessagesHaveErrors tgt.path "parsing" messages
  let (env, messages) ← processHeader header opts messages inputCtx
  throwIfMessagesHaveErrors tgt.path "processing imports for" messages
  let commandState := { Command.mkState env messages opts with infoState.enabled := true }
  let s ← IO.processCommands inputCtx parserState commandState
  throwIfMessagesHaveErrors tgt.path "processing" s.commandState.messages
  go s

unsafe def withInfoTrees (tgt : InputTarget) (opts : Options) (go : InfoTree → IO α) : IO (PersistentArray α) :=
  tgt.processCommands opts fun s => s.commandState.infoState.trees.mapM go

unsafe def withVisitM
    (tgt : InputTarget) (opts : Options)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (PersistentArray (Option α)) := do
  tgt.withInfoTrees opts fun tree => tree.visitM preNode postNode ctx?

end InputTarget

namespace SetupTarget

unsafe def withInfoTrees (tgt : SetupTarget) (opts : Options) (go : InfoTree → IO α) : IO (PersistentArray α) := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let setup ← Lean.ModuleSetup.load tgt.setupFile
  let inputCtx ← tgt.inputCtx
  let opts := applyCmdlineFrontendDefaults opts
  let setupFn stx := do
    liftM <| setup.dynlibs.forM Lean.loadDynlib
    return .ok {
      trustLevel := 0
      package? := setup.package?
      mainModuleName := setup.name
      isModule := setup.isModule || stx.isModule
      imports := setup.imports?.getD stx.imports
      plugins := setup.plugins
      importArts := setup.importArts
      opts := opts.mergeBy (fun _ _ hOpt => hOpt) setup.options.toOptions
    }
  let snap ← Language.Lean.process setupFn none { inputCtx with }
  let snaps := Language.toSnapshotTree snap
  let messages := snaps.getAll.map (·.diagnostics.msgLog) |>.foldl (· ++ ·) {}
  throwIfMessagesHaveErrors tgt.path "processing" messages
  let some parsed := snap.result?
    | throw <| IO.userError s!"Lean failed to initialize processing for '{tgt.path}'"
  let some processed := parsed.processedSnap.get.result?
    | throw <| IO.userError s!"Lean failed to process header for '{tgt.path}'"
  collectCommandInfoTrees processed.firstCmdSnap.get |>.toPArray' |>.mapM go

unsafe def withVisitM
    (tgt : SetupTarget) (opts : Options)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (PersistentArray (Option α)) := do
  tgt.withInfoTrees opts fun tree => tree.visitM preNode postNode ctx?

end SetupTarget

unsafe def Target.withInfoTrees (tgt : Target) (opts : Options) (go : InfoTree → IO α) : IO (PersistentArray α) :=
  match tgt with
  | .input tgt => tgt.withInfoTrees opts go
  | .setup tgt => tgt.withInfoTrees opts go
  | _ => throw <| IO.userError "Unsupported Target"

unsafe def Target.withVisitM
    (tgt : Target) (opts : Options)
    (preNode : ContextInfo → Info → PersistentArray InfoTree → IO Bool)
    (postNode : ContextInfo → Info → PersistentArray InfoTree → List (Option α) → IO α)
    (ctx? : Option ContextInfo) : IO (PersistentArray (Option α)) := do
  tgt.withInfoTrees opts fun tree => tree.visitM preNode postNode ctx?

namespace ImportsTarget

unsafe def withEnv (tgt : ImportsTarget) (opts : Options) (go : Environment → IO α) : IO α := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let env ← Lean.importModules (loadExts := true) tgt.imports opts
  go env

unsafe def runCoreM (tgt : ImportsTarget) (opts : Options) (go : CoreM α) : IO α := do
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

This function uses `TaskPool.runForMChecked_` internally, which iterates directly over `env.constants`
without pre-collecting them into an array, making it memory-efficient for large environments.
-/
unsafe def runParallelCoreM (tgt : ImportsTarget) (opts : Options)
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

    let poolConfig : TaskPool.Config := {
      maxConcurrent := maxTasks
      failFast := true
    }
    TaskPool.runForMChecked_ env.constants
      (fun (n, c) => (go env n c |>.toIO ctx state) <&> Prod.fst)
      poolConfig

end ImportsTarget

end LeanScout
