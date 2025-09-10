module

public import LeanScout

def tacFilter : Lean.SyntaxNodeKinds := [
  `«;»,
  `Lean.cdotTk,
  `«]»,
  Lean.nullKind,
  `«by»,
  `Lean.Parser.Tactic.withAnnotateState,
  `Lean.Parser.Tactic.tacticSeq,
  `Lean.Parser.Tactic.tacticSeq1Indented,
  `Lean.Parser.Term.byTactic
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
      handle.putStrLn <| Lean.Json.compress <| json% {
        stx : $(toString info.stx.prettyPrint)
      }
