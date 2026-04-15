/-
Regression fixture for the tactics extractor.

Historically, the extractor evaluated `TacticInfo.goalsBefore` in the current
`ContextInfo.mctx` instead of `TacticInfo.mctxBefore`. For certain `grind =>`
sequences, Lean had already discarded the original goal metavariable from the
current metavariable context, and tactics extraction crashed with:

  unknown metavariable `?_uniq...`

This file is intentionally self-contained and does not depend on mathlib.
-/
module

example {n x y : Nat}
  (hxy : 2 * n < x + y)
  (hcounter : ∀ a : Nat, a ≤ n ∨ ¬ a = x ∧ ¬ a = y) :
  False := by
  grind =>
    have : n < x ∨ n < y
    tactic =>
      cases this with
      | inl hxgt =>
          have hx := hcounter x
          cases hx with
          | inl hxle => omega
          | inr hxneq => exact hxneq.1 rfl
      | inr hygt =>
          have hy := hcounter y
          cases hy with
          | inl hyle => omega
          | inr hyneq => exact hyneq.2 rfl
