import ElmLean.Proofs.Spec
import Counter.App

/-! What is proven about Counter: two effect lemmas, and a `Spec` whose `Target` says that `-` is
only ever clickable while the count is positive and that every note control names an existing note. -/

namespace Counter
open ElmLean

/-- `+` raises the count by exactly one. -/
theorem count_inc (m : Model) : (update .inc m).count = m.count + 1 := by
  simp [update]

/-- `-` never raises the count. -/
theorem count_dec_le (m : Model) : (update .dec m).count ≤ m.count := by
  simp only [update]
  exact Nat.sub_le _ _

/-- A message makes sense in `m`: `-` only while the count is positive, note controls only for
existing notes. -/
@[simp] def WellTargeted (m : Model) : Msg → Prop
  | .inc => True
  | .dec => 0 < m.count
  | .setDraft _ => True
  | .addNote => True
  | .setDone id _ => ∃ n ∈ m.notes, n.id = id
  | .delete id => ∃ n ∈ m.notes, n.id = id
  | .setFilter _ => True
  | .clear => True

theorem mem_visible {m : Model} {n : Note} (h : n ∈ visible m) : n ∈ m.notes := by
  unfold visible at h; split at h
  · exact h
  · exact (List.mem_filter.1 h).1

/-- Every handler in the view yields a well-targeted message. -/
theorem view_sat (m : Model) : Html.Sat (WellTargeted m) (view m) := by
  unfold view; refine .col _ ?_; intro c hc
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
  rcases hc with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
  · exact .text _ _
  · refine .row _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl
    · exact .button _ _ _ (fun _ h => by split at h <;> cases h; simp; omega)
    · exact .text _ _
    · exact .button _ _ _ (fun _ h => by cases h; simp)
  · refine .row _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl
    · exact .field _ _ _ _ (fun _ => by simp) (fun _ h => by cases h; simp)
    · exact .button _ _ _ (fun _ h => by split at h <;> cases h; simp)
  · refine .col _ ?_; intro c hc; obtain ⟨n, hn, rfl⟩ := List.mem_map.1 hc
    refine .row _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl
    · exact .toggle _ _ _ (fun _ => ⟨n, mem_visible hn, rfl⟩)
    · exact .spacer
    · exact .button _ _ _ (fun _ h => by cases h; exact ⟨n, mem_visible hn, rfl⟩)
  · exact .divider
  · refine .row _ ?_; intro c hc; simp only [filterButton, List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl <;> exact .button _ _ _ (fun _ h => by cases h; simp)
  · exact .text _ _
  · exact .button _ _ _ (fun _ h => by split at h <;> cases h; simp)

/-- Counter's `Spec`: no invariant needed (`True`), `WellTargeted` as the target. -/
def spec : Spec app where
  Inv := fun _ => True
  Target := WellTargeted
  init_inv := trivial
  update_inv := fun _ _ _ => trivial
  view_sat := fun m _ => view_sat m

/-- After any request trace, an in-sync request for an advertised control runs `update` on a
well-targeted message: in particular `-` is never accepted at count zero. -/
theorem counter_reachable_sound (rs : List Request) (r : Request)
    (hseq : r.seq = (Session.reach app rs).seq)
    (hadv : (Session.reach app rs).lastView.toWire.advertises r.path r.event = true) :
    ∃ msg, (Session.reach app rs).lastView.dispatch r.path r.event = some msg
      ∧ WellTargeted (Session.reach app rs).model msg
      ∧ ((Session.reach app rs).handle app r).1.model = update msg (Session.reach app rs).model := by
  obtain ⟨msg, hd, ht, hm, _⟩ := spec.reachable_sound rs r hseq hadv
  exact ⟨msg, hd, ht, hm⟩

end Counter
