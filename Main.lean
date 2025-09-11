module

public import LeanScout

namespace LeanScout

open Lean

def tacFilter : Lean.SyntaxNodeKinds := [
  `Lean.Parser.Term.byTactic,
  `Lean.Parser.Tactic.tacticSeq,
  `Lean.Parser.Tactic.tacticSeq1Indented,
  `Lean.Parser.Tactic.withAnnotateState,
  `Lean.cdotTk,
  `«by»,
  `«;»,
  `«]»,
  Lean.nullKind,
]

-- A more agressive Variant of `Lean.Name.isBlackListed`.
-- TODO: We need a more robust way to ignore internal constants.
def declNameFilter {m} [Monad m] [MonadEnv m] (declName : Name) : m Bool := do
  if declName == ``sorryAx then return true
  if declName matches .str _ "inj" then return true
  if declName matches .str _ "injEq" then return true
  if declName matches .str _ "rec" then return true
  if declName matches .str _ "recOn" then return true
  if declName matches .str _ "sizeOf_spec" then return true
  if declName matches .str _ "brecOn" then return true
  if declName matches .str _ "recOn" then return true
  if declName matches .str _ "casesOn" then return true
  if declName matches .str _ "toCtorIdx" then return true
  if declName matches .str _ "noConfusionType" then return true
  if declName.components.contains `Grind then return true
  if declName.components.contains `Omega then return true
  if declName.isInternalDetail then return true
  let env ← getEnv
  if isAuxRecursor env declName then return true
  if isNoConfusion env declName then return true
  if ← isRec declName then return true
  if ← Meta.isMatcher declName then return true
  return false

structure Options where
  args : List String

inductive Command where
  | tactics
  | types

abbrev M := ReaderT (Command × Options) IO

def getOptions : M Options := read <&> Prod.snd
def getArgs : M (List String) := getOptions <&> Options.args

def run (args : List String) (go : M α) : IO α := do
  match args with
  | "tactics" :: args => go (.tactics, .mk args)
  | "types" :: args => go (.types, .mk args)
  | _ => throw <| .userError "Usage: scout <COMMAND> [args]"

unsafe
def tactics : M Unit := do
  let args ← getArgs
  let some srcPath := args[0]? | throw <| .userError "Path expected"
  let some dataPath := args[1]? | throw <| .userError "Module expected"
  if let some parentDir := (System.FilePath.mk dataPath).parent then
    IO.FS.createDirAll parentDir
  IO.FS.withFile (.mk dataPath) .write fun handle => do
    let tgt ← LeanScout.Target.read <| System.FilePath.mk srcPath |>.normalize
    discard <| tgt.withVisitM
        (α := Unit) (ctx? := none) (fun _ _ _ => return true)
        fun ctxInfo info _children _ => ctxInfo.runMetaM {} do
      let .ofTacticInfo info := info | return
      let some (.original ..) := info.stx.getHeadInfo? | return
      if tacFilter.contains info.stx.getKind then return
      let ppTac : String := toString info.stx.prettyPrint
      let ppGoals : List String ← info.goalsBefore.mapM fun mvarId =>
        mvarId.withContext do
          let goal ← Lean.Meta.ppGoal mvarId
          return toString goal
      handle.putStrLn <| Lean.Json.compress <| json% {
        ppGoals : $(ppGoals),
        ppTac : $(ppTac)
      }

unsafe
def types : M Unit := do
  let args ← getArgs
  let tgt := Target.mkImports args.toArray
  tgt.withInfoTrees fun trees => do for tree in trees do
    match tree with
    | .context (.commandCtx ctx) (.node (.ofCommandInfo ⟨``Lean.Elab.Command.elabEoi, _⟩) _) =>
      let ctx : Lean.Elab.ContextInfo := { ctx with }
      ctx.runMetaM' {} do
        let env ← getEnv
        for (n, c) in env.constants do
          if ← declNameFilter n then continue
          println! Json.compress <| json% {
            name : $(n),
            type : $(s!"{← Meta.ppExpr c.type}")
          }
    | _ => continue

unsafe
def main : M Unit := do
  match (← read).fst with
  | .tactics => tactics
  | .types => types

end LeanScout

open LeanScout

public unsafe def main (args : List String) :=
  LeanScout.run args LeanScout.main
