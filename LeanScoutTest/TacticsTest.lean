theorem foo (a b : Nat) : a + b = b + a := by
  try done
  rw [Nat.add_comm]
