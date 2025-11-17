-- Test file 1 for parallel extraction

def testFunc1 : Nat := 42

theorem testTheorem1 : testFunc1 = 42 := by
  rfl

example : 1 + 1 = 2 := by
  rfl

example : 2 + 2 = 4 := by
  rfl
