module

public import Lean.Elab.InfoTree

namespace Lean.Elab.ContextInfo

public section

/--
Similar to `Lean.Elab.ContextInfo.runCoreM`, but fixes an issue with heartbeats.
See
-/
def runCoreM' (info : ContextInfo) (x : CoreM α) : IO α := do
  let initHeartbeats ← IO.getNumHeartbeats
  Prod.fst <$> x.toIO
    { currNamespace := info.currNamespace,
      openDecls := info.openDecls,
      fileName := "<InfoTree>",
      fileMap := default,
      initHeartbeats := initHeartbeats,
      maxHeartbeats := maxHeartbeats.get info.options,
      options := info.options }
    { env := info.env, ngen := info.ngen }

def runMetaM' (info : ContextInfo) (lctx : LocalContext) (x : MetaM α) : IO α := do
  Prod.fst <$> info.runCoreM' (x.run { lctx := lctx } { mctx := info.mctx })
