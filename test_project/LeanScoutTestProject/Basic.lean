import Init.Data.Nat.Basic

theorem add_zero (n : Nat) : n + 0 = n := by
  rfl

theorem zero_add (n : Nat) : 0 + n = n := by
  rw [Nat.zero_add]

theorem succ_eq_add_one (n : Nat) : n.succ = n + 1 := by
  rfl

theorem add_comm (a b : Nat) : a + b = b + a := by
  induction a with
  | zero =>
    rw [Nat.zero_add, Nat.add_zero]
  | succ n ih =>
    rw [Nat.succ_add, Nat.add_succ, ih]
