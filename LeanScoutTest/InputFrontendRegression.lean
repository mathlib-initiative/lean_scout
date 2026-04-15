/-
Regression fixture for Lean Scout's input-mode frontend.

Historically, Lean Scout's manual frontend in `--read` mode diverged from
`lake env lean` and failed on this file with:

  Unknown identifier `privateWitness`

The failure required a module file using `@[expose] public section`,
`backward.privateInPublic`, a private theorem, and a later public `def`
referencing it. The final theorem provides a tactic block so the `tactics`
extractor emits JSONL output in the integration test.
-/
module

@[expose] public section

set_option backward.privateInPublic true in
private theorem privateWitness : True := True.intro

set_option backward.privateInPublic true in
def exportedWitness := privateWitness

theorem usesExportedWitness : True := by
  exact exportedWitness
