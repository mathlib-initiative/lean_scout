-- Test file 2 for parallel extraction

def testFunc2 : String := "hello"

theorem testTheorem2 : testFunc2.length = 5 := by
  rfl

example : 3 + 3 = 6 := by
  rfl

example : List.length [1, 2, 3, 4] = 4 := by
  rfl
