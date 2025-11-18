import Init.Prelude

theorem list_nil_append {α : Type} (xs : List α) :
  [] ++ xs = xs := by
  rfl

theorem list_cons_append {α : Type} (x : α) (xs ys : List α) :
  (x :: xs) ++ ys = x :: (xs ++ ys) := by
  rfl

theorem list_length_nil {α : Type} :
  ([] : List α).length = 0 := by
  rfl

theorem list_map_nil {α β : Type} (f : α → β) :
  ([] : List α).map f = [] := by
  rfl
