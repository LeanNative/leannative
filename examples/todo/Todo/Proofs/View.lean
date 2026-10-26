import Todo.View
import ElmLean.Proofs.Sat

/-! Theorems about the Todo `view`: the rendered tree has one toggle per visible
todo, the toggles are labelled by the visible titles, the row controls dispatch to
messages naming the right ids (their effect on the model is in `Proofs/TodoUpdate.lean`),
and every advertised control dispatches to a well-targeted message. -/

namespace Todo
open ElmLean

theorem sum_const_one {α : Type} : ∀ l : List α, (l.map (fun _ => 1)).sum = l.length
  | [] => rfl
  | _ :: l => by rw [List.map_cons, List.sum_cons, List.length_cons, sum_const_one l]; omega

theorem flatten_map_singleton {α β : Type} (f : α → β) :
    ∀ l : List α, (l.map (fun a => [f a])).flatten = l.map f
  | [] => rfl
  | a :: l => by
    rw [List.map_cons, List.flatten_cons, List.singleton_append, List.map_cons,
      flatten_map_singleton f l]

@[simp] theorem countToggles_todoRow (t : Todo) : (todoRow t).countToggles = 1 := by
  simp [todoRow, Html.countToggles]

@[simp] theorem toggleLabels_todoRow (t : Todo) : (todoRow t).toggleLabels = [t.title] := by
  simp [todoRow, Html.toggleLabels]

theorem mem_visible {m : Model} {t : Todo} (h : t ∈ visible m) : t ∈ m.todos := by
  unfold visible at h; split at h <;> simp_all [List.mem_filter]

/-- V1: exactly one toggle per visible todo. -/
theorem countToggles_view (m : Model) : (view m).countToggles = (visible m).length := by
  simp [view, Html.countToggles, filterButton, Function.comp_def, sum_const_one]

/-- V2: the toggles are labelled by the visible titles, in order. -/
theorem toggleLabels_view (m : Model) : (view m).toggleLabels = (visible m).map (·.title) := by
  simp [view, Html.toggleLabels, filterButton, Function.comp_def, flatten_map_singleton]

/-- V3a: the Delete button of row `i` dispatches to `delete` of exactly the `i`-th visible
todo's id. This identifies the *message* only; what `update` then does with it is stated by
the effect lemmas in `Proofs/TodoUpdate.lean`: `delete_mem_iff` (exactly the todos with another
id survive) and `delete_length` (under `Model.Inv`, exactly one todo is removed). -/
theorem delete_dispatch (m : Model) (i : Nat) (hi : i < (visible m).length) :
    (view m).dispatch [2, i, 2] .click = some (.delete (visible m)[i].id) := by
  simp [Html.dispatch, Html.at?, Html.children, view, List.getElem?_map,
    List.getElem?_eq_getElem hi, todoRow, Html.handle]

/-- V3b: the toggle of row `i` dispatches to `setDone` of exactly the `i`-th visible todo's
id, carrying the value `b` the renderer sent. Again this identifies the *message* only; its
effect is stated by the `setDone_*` lemmas in `Proofs/TodoUpdate.lean`: `setDone_target_done`
and `setDone_mem_target` (the target's done flag becomes `b`), `setDone_mem_other` and
`setDone_mem_other'` (every other todo is untouched), `setDone_ids` and `setDone_titles` (ids,
titles and order are kept), and `setDone_idem`, which is idempotency at the *message* level:
two `setDone` messages with the same id and value equal one, because `value` is authoritative.
That is exactly what PROTOCOL.md's toggle sentence claims, and no more: at the wire level the
same `path` may name another row once the view has changed (under the Active filter the first
toggle hides its row, so a second `[2, i, 0]` hits the next todo), which the client rules for
queued events prevent by dropping a toggle created against an older `seq`. -/
theorem toggle_dispatch (m : Model) (i : Nat) (hi : i < (visible m).length) (b : Bool) :
    (view m).dispatch [2, i, 0] (.toggle b) = some (.setDone (visible m)[i].id b) := by
  simp [Html.dispatch, Html.at?, Html.children, view, List.getElem?_map,
    List.getElem?_eq_getElem hi, todoRow, Html.handle]

/-- V4a: the footer caption reports the remaining count. -/
theorem footer_text (m : Model) :
    (view m).at? [5] = some (.text s!"{remaining m} left" .caption) := by
  simp [Html.at?, Html.children, view]

/-- V4b: the Add button is enabled iff the trimmed draft is non-empty. -/
theorem add_enabled_iff (m : Model) :
    (view m).dispatch [1, 1] .click = some .add ↔ (trimTitle m.draft).isEmpty = false := by
  simp [Html.dispatch, Html.at?, Html.children, view, Html.handle]

/-- V5: every handler in the view yields a well-targeted message. -/
theorem view_sat (m : Model) : Html.Sat (WellTargeted m) (view m) := by
  unfold view; refine .col _ ?_; intro c hc
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
  rcases hc with rfl | rfl | rfl | rfl | rfl | rfl | rfl
  · exact .text _ _
  · refine .row _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl
    · exact .field _ _ _ _ (fun _ => by simp) (fun _ h => by cases h; simp)
    · exact .button _ _ _ (fun _ h => by split at h <;> cases h; simp)
  · refine .col _ ?_; intro c hc; obtain ⟨t, ht, rfl⟩ := List.mem_map.1 hc
    refine .row _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl
    · exact .toggle _ _ _ (fun _ => ⟨t, mem_visible ht, rfl⟩)
    · exact .spacer
    · exact .button _ _ _ (fun _ h => by cases h; exact ⟨t, mem_visible ht, rfl⟩)
  · exact .divider
  · refine .row _ ?_; intro c hc; simp only [filterButton, List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl <;> exact .button _ _ _ (fun _ h => by cases h; simp)
  · exact .text _ _
  · exact .button _ _ _ (fun _ h => by split at h <;> cases h; simp)

/-- V6: an advertised control of the rendered view dispatches to a well-targeted message. -/
theorem view_sound (m : Model) (p : List Nat) (e : Event)
    (hadv : (view m).toWire.advertises p e = true) :
    ∃ msg, (view m).dispatch p e = some msg ∧ WellTargeted m msg := by
  have := (Html.advertises_iff _ _ _).1 hadv
  cases hd : (view m).dispatch p e with
  | none => simp [hd] at this
  | some msg => exact ⟨msg, rfl, Html.Sat.dispatch p _ (view_sat m) e msg hd⟩

end Todo
