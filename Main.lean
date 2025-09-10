module

public import LeanScout

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

public unsafe def main (args : List String) : IO Unit := do
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
