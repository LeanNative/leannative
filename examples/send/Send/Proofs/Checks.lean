import Send.App

/-! What the app's checks mean: `authorizes`, `matchesForm` and the multiset comparisons, stated
with `=` and `List.Perm`. -/

namespace Send

theorem sameOut_iff (a b : Out) : sameOut a b = true ↔ a = b := by
  cases a; cases b; simp [sameOut]

theorem countOut_eq (o : Out) (xs : List Out) : countOut o xs = xs.count o := by
  unfold countOut
  rw [List.count_eq_length_filter]
  congr 1
  apply List.filter_congr
  intro x _
  cases h : sameOut x o
  · have : x ≠ o := fun e => by rw [(sameOut_iff x o).2 e] at h; cases h
    simp [this]
  · simp [(sameOut_iff x o).1 h]

theorem countStr_eq (s : String) (xs : List String) : countStr s xs = xs.count s := by
  unfold countStr
  rw [List.count_eq_length_filter]

/-- Equal counts for every element of either list is equal counts everywhere. -/
theorem counts_all {α : Type} [BEq α] [LawfulBEq α] (xs ys : List α) :
    (xs.all (fun o => xs.count o == ys.count o) && ys.all (fun o => xs.count o == ys.count o)) = true ↔
      xs.Perm ys := by
  rw [List.perm_iff_count]
  simp only [Bool.and_eq_true, List.all_eq_true, beq_iff_eq]
  constructor
  · intro ⟨h1, h2⟩ a
    by_cases ha : a ∈ xs
    · exact h1 a ha
    · by_cases hb : a ∈ ys
      · exact h2 a hb
      · rw [List.count_eq_zero.2 ha, List.count_eq_zero.2 hb]
  · intro h; exact ⟨fun a _ => h a, fun a _ => h a⟩

theorem sameOuts_iff (xs ys : List Out) : sameOuts xs ys = true ↔ xs.Perm ys := by
  rw [← counts_all]
  simp only [sameOuts, countOut_eq]

theorem sameStrs_iff (xs ys : List String) : sameStrs xs ys = true ↔ xs.Perm ys := by
  rw [← counts_all]
  simp only [sameStrs, countStr_eq]

/-- THE CHECK BEFORE ANY BROADCAST, in plain terms: the signed transaction answers the draft, has
the draft's fee and change amount, spends the draft's coins, and its outputs are exactly the payment
of `d.amount` sats to `d.script` plus the draft's change, in some order, with nothing else. -/
theorem authorizes_iff (d : Draft) (s : Signed) :
    authorizes d s = true ↔
      s.draftId = d.id ∧ s.fee = d.fee ∧ s.changeAmount = changeAmountOf d ∧
      s.inputs.Perm d.inputs ∧ s.outputs.Perm (expectedOutputs d) := by
  simp only [authorizes, Bool.and_eq_true, beq_iff_eq, sameStrs_iff, sameOuts_iff, and_assoc]

theorem expectedOutputs_eq (d : Draft) :
    expectedOutputs d = ⟨d.amount, d.script⟩ :: (match d.change with | some c => [c] | none => []) := by
  unfold expectedOutputs; cases d.change <;> rfl

/-- A draft matches a form: it was made for exactly these inputs, its amount is the number typed and
its address is the address typed (both trimmed). -/
theorem matchesForm_iff (f : Entry) (d : Draft) :
    matchesForm f d = true ↔
      d.form = f ∧ toString d.amount = trim f.amount ∧ d.destination = trim f.destination := by
  obtain ⟨a, b, c⟩ := f
  obtain ⟨_, ⟨a', b', c'⟩, _⟩ := d
  simp [matchesForm, sameForm, and_assoc]

end Send
