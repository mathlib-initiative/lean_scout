import Lean

example (a b : Prop) (h : a → b) (ha : a) : b := by
  apply h
  assumption
