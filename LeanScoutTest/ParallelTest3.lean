-- Test file 3 for parallel extraction

def testFunc3 : List Nat := [1, 2, 3]

theorem testTheorem3 : testFunc3.length = 3 := by
  rfl

example : 5 + 5 = 10 := by
  rfl

example : 10 - 5 = 5 := by
  rfl
