-- Test various tactics from Lean core

-- Basic rewrite tactics
theorem test_rw (a b : Nat) : a + b = b + a := by
  rw [Nat.add_comm]

-- Exact and trivial
theorem test_exact (n : Nat) : n = n := by
  exact rfl

-- Reflexivity
theorem test_rfl (x : Nat) : x = x := by
  rfl

-- Apply tactic
theorem test_apply (a b c : Nat) (h1 : a = b) (h2 : b = c) : a = c := by
  apply Eq.trans
  exact h1
  exact h2

-- Intro tactic
theorem test_intro (P Q : Prop) : P → Q → P := by
  intro hp
  intro hq
  exact hp

-- Cases tactic with Or
theorem test_cases_or (P Q R : Prop) (h : P ∨ Q) (hp : P → R) (hq : Q → R) : R := by
  cases h with
  | inl p => exact hp p
  | inr q => exact hq q

-- Cases tactic with And
theorem test_cases_and (P Q : Prop) (h : P ∧ Q) : Q ∧ P := by
  cases h with
  | intro p q => exact ⟨q, p⟩

-- Cases on Nat
theorem test_cases_nat (n : Nat) : n = 0 ∨ ∃ m, n = m + 1 := by
  cases n with
  | zero => exact Or.inl rfl
  | succ m => exact Or.inr ⟨m, rfl⟩

-- Induction tactic
theorem test_induction (n : Nat) : n + 0 = n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    rw [Nat.add_succ, ih]

-- Have tactic
theorem test_have (a b c : Nat) (h1 : a = b) (h2 : b = c) : a = c := by
  have h3 : a = b := h1
  rw [h3, h2]

-- Assumption tactic
theorem test_assumption (P : Prop) (h : P) : P := by
  assumption

-- Constructor tactic
theorem test_constructor_and (P Q : Prop) (hp : P) (hq : Q) : P ∧ Q := by
  constructor
  exact hp
  exact hq

-- Left and right for Or
theorem test_left (P Q : Prop) (hp : P) : P ∨ Q := by
  left
  exact hp

theorem test_right (P Q : Prop) (hq : Q) : P ∨ Q := by
  right
  exact hq

-- Contradiction
theorem test_contradiction (P : Prop) (h : P) (hn : ¬P) : False := by
  contradiction

-- Exfalso
theorem test_exfalso (P : Prop) (h : False) : P := by
  exfalso
  exact h

-- Trivial with True
theorem test_trivial : True := by
  trivial

-- Subst tactic
theorem test_subst (a b c : Nat) (h1 : a = b) (h2 : b = c) : a = c := by
  subst h1
  exact h2

-- Simp tactic
theorem test_simp (xs : List Nat) : xs ++ [] = xs := by
  simp

-- Revert and intro
theorem test_revert_intro (n : Nat) (h : n = n) : n = n := by
  revert h
  intro h
  exact h

-- Clear tactic
theorem test_clear (n : Nat) (h : n = n) (_h2 : n > 0) : n = n := by
  exact h

-- Generalize tactic
theorem test_generalize (a b : Nat) (h : a = b) : a + 1 = b + 1 := by
  generalize a = x at h ⊢
  rw [h]

-- Split (for if-then-else or match)
theorem test_split (n : Nat) : (if n = 0 then 1 else 2) ≥ 1 := by
  split
  · decide
  · decide

-- Decide (for decidable props)
theorem test_decide : 2 + 2 = 4 := by
  decide

-- Unfold
def myId (n : Nat) : Nat := n

theorem test_unfold (n : Nat) : myId n = n := by
  unfold myId
  rfl

-- Calc tactic
theorem test_calc (a b c : Nat) (h1 : a = b) (h2 : b = c) : a = c := by
  calc a = b := h1
       _ = c := h2

-- Try tactic
theorem test_try (n : Nat) : n = n := by
  try rw [Nat.add_comm]
  rfl

-- Repeat tactic
theorem test_repeat (xs : List Nat) : xs ++ [] ++ [] = xs := by
  repeat rw [List.append_nil]

-- First tactic
theorem test_first (n : Nat) : n = n := by
  first | rfl | exact rfl

-- Focus on single goal
theorem test_focus (P Q : Prop) (hp : P) (hq : Q) : P ∧ Q := by
  constructor
  · exact hp
  · exact hq

-- All goals
theorem test_all_goals (P Q : Prop) (h : P ∧ Q) : Q ∧ P := by
  constructor
  all_goals cases h; assumption

-- Any goals
theorem test_any_goals (n : Nat) : n + 0 = n ∧ 0 + n = n := by
  constructor
  any_goals simp [Nat.add_zero, Nat.zero_add]
