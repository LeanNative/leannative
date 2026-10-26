import Todo.Update

/-! `Model.Inv` (distinct ids, ids below `nextId`, non-empty titles) holds initially
and is preserved by every `update`; and the *effect lemmas* for `setDone` and `delete`,
which say what those two messages do to the todo list (the V3a/V3b dispatch theorems in
`Proofs/TodoView.lean` only identify the message a row control dispatches). -/

namespace Todo
open ElmLean

@[simp] theorem setDoneIf_id (id : Nat) (b : Bool) (t : Todo) : (setDoneIf id b t).id = t.id := by
  unfold setDoneIf; split <;> rfl

@[simp] theorem setDoneIf_title (id : Nat) (b : Bool) (t : Todo) : (setDoneIf id b t).title = t.title := by
  unfold setDoneIf; split <;> rfl

theorem inv_filter (m : Model) (p : Todo → Bool) (h : m.Inv) :
    Model.Inv { m with todos := m.todos.filter p } := by
  obtain ⟨hpw, hlt, hne⟩ := h
  exact ⟨hpw.filter p, fun t ht => hlt t (List.mem_filter.1 ht).1,
    fun t ht => hne t (List.mem_filter.1 ht).1⟩

theorem init_inv : Model.init.Inv := ⟨.nil, by simp [Model.init], by simp [Model.init]⟩

theorem update_inv (msg : Msg) (m : Model) (h : m.Inv) : (update msg m).Inv := by
  obtain ⟨hpw, hlt, hne⟩ := h
  cases msg with
  | setDraft s  => exact ⟨hpw, hlt, hne⟩
  | setFilter f => exact ⟨hpw, hlt, hne⟩
  | delete id   => exact inv_filter m _ ⟨hpw, hlt, hne⟩
  | clearDone   => exact inv_filter m _ ⟨hpw, hlt, hne⟩
  | setDone id b =>
    refine ⟨?_, ?_, ?_⟩
    · simp only [update]; rw [List.pairwise_map]; exact hpw.imp (by intro a b hab; simpa using hab)
    · intro t ht; simp only [update] at ht ⊢; obtain ⟨t', ht', rfl⟩ := List.mem_map.1 ht
      simpa using hlt t' ht'
    · intro t ht; simp only [update] at ht ⊢; obtain ⟨t', ht', rfl⟩ := List.mem_map.1 ht
      simpa using hne t' ht'
  | add =>
    simp only [update]; split
    · exact ⟨hpw, hlt, hne⟩
    · rename_i hempty; refine ⟨?_, ?_, ?_⟩
      · rw [List.pairwise_cons]; refine ⟨fun t ht => ?_, hpw⟩; have := hlt t ht; simp; omega
      · intro t ht; rw [List.mem_cons] at ht; rcases ht with rfl | ht
        · simp
        · have := hlt t ht; simp; omega
      · intro t ht; rw [List.mem_cons] at ht; rcases ht with rfl | ht
        · simpa using hempty
        · exact hne t ht

/-! ## Effect lemmas: what `setDone` and `delete` do to the list -/

theorem setDoneIf_idem (id : Nat) (b : Bool) (t : Todo) :
    setDoneIf id b (setDoneIf id b t) = setDoneIf id b t := by
  by_cases h : t.id = id <;> simp [setDoneIf, h]

/-- Two identical `setDone` messages in a row are one: the toggle's `value` is authoritative,
so the repeated or retried toggles PROTOCOL.md calls idempotent really are. -/
theorem setDone_idem (id : Nat) (b : Bool) (m : Model) :
    update (.setDone id b) (update (.setDone id b) m) = update (.setDone id b) m := by
  simp [update, List.map_map, Function.comp_def, setDoneIf_idem]

/-- `setDone` leaves the ids, and their order, untouched. -/
theorem setDone_ids (id : Nat) (b : Bool) (m : Model) :
    (update (.setDone id b) m).todos.map (·.id) = m.todos.map (·.id) := by
  simp [update, List.map_map, Function.comp_def]

/-- `setDone` leaves the titles, and their order, untouched. -/
theorem setDone_titles (id : Nat) (b : Bool) (m : Model) :
    (update (.setDone id b) m).todos.map (·.title) = m.todos.map (·.title) := by
  simp [update, List.map_map, Function.comp_def]

/-- The target todo survives with its done flag set to `b`. -/
theorem setDone_mem_target (id : Nat) (b : Bool) (m : Model) :
    ∀ t ∈ m.todos, t.id = id → { t with done := b } ∈ (update (.setDone id b) m).todos := by
  intro t ht h
  simp only [update]
  exact List.mem_map.2 ⟨t, ht, by simp [setDoneIf, h]⟩

/-- Afterwards every todo carrying the target id has done flag `b`. -/
theorem setDone_target_done (id : Nat) (b : Bool) (m : Model) :
    ∀ t ∈ (update (.setDone id b) m).todos, t.id = id → t.done = b := by
  intro t ht h
  simp only [update] at ht
  obtain ⟨t', _, rfl⟩ := List.mem_map.1 ht
  simp only [setDoneIf_id] at h
  simp [setDoneIf, h]

/-- Every other todo of the new list was already in the old one, unchanged. -/
theorem setDone_mem_other (id : Nat) (b : Bool) (m : Model) :
    ∀ t ∈ (update (.setDone id b) m).todos, t.id ≠ id → t ∈ m.todos := by
  intro t ht h
  simp only [update] at ht
  obtain ⟨t', ht', rfl⟩ := List.mem_map.1 ht
  simp only [setDoneIf_id] at h
  simpa [setDoneIf, h] using ht'

/-- ...and every other todo of the old list is still there, unchanged. -/
theorem setDone_mem_other' (id : Nat) (b : Bool) (m : Model) :
    ∀ t ∈ m.todos, t.id ≠ id → t ∈ (update (.setDone id b) m).todos := by
  intro t ht h
  simp only [update]
  exact List.mem_map.2 ⟨t, ht, by simp [setDoneIf, h]⟩

/-- `delete id` keeps exactly the todos whose id is not `id`. -/
theorem delete_mem_iff (id : Nat) (m : Model) :
    ∀ t, t ∈ (update (.delete id) m).todos ↔ t ∈ m.todos ∧ t.id ≠ id := by
  intro t
  simp [update, List.mem_filter]

/-- Filtering out one id from a list of pairwise-distinct ids removes exactly one element. -/
theorem length_filter_ne_id {t : Todo} :
    ∀ {l : List Todo}, l.Pairwise (fun a b => a.id ≠ b.id) → t ∈ l →
      (l.filter (fun x => x.id != t.id)).length + 1 = l.length
  | [], _, ht => absurd ht (List.not_mem_nil)
  | a :: l, hpw, ht => by
    rw [List.pairwise_cons] at hpw
    obtain ⟨ha, hpw⟩ := hpw
    rw [List.mem_cons] at ht
    rcases ht with rfl | ht
    · -- the head is the target: it is dropped and, ids being distinct, nothing else is
      have hkeep : l.filter (fun x => x.id != t.id) = l :=
        List.filter_eq_self.2 fun x hx => bne_iff_ne.2 (Ne.symm (ha x hx))
      simp [hkeep]
    · -- the head is kept (its id differs from the target's) and the tail loses exactly one
      have hne : (a.id != t.id) = true := bne_iff_ne.2 (ha t ht)
      rw [List.filter_cons_of_pos (p := fun x : Todo => x.id != t.id) hne, List.length_cons,
        List.length_cons, length_filter_ne_id hpw ht]

/-- Under the invariant (ids pairwise distinct), deleting an existing todo's id removes
exactly one todo. -/
theorem delete_length (m : Model) (h : m.Inv) {t : Todo} (ht : t ∈ m.todos) :
    (update (.delete t.id) m).todos.length + 1 = m.todos.length := by
  simp only [update]
  exact length_filter_ne_id h.1 ht

end Todo
