import ElmLean.Program
import ElmLean.Proofs.Erase

/-! Theorems about the protocol step `Session.handle` for an arbitrary `App`:
an advertised request with the right `seq` is answered with a fresh view, the
session's `lastView` stays coherent with its model, and any invariant preserved
by `update` is preserved by every step and every run. -/

namespace ElmLean

variable {Model Msg : Type}

/-- A request against the current view that the wire advertises is never rejected. -/
theorem Session.handle_advertised (app : App Model Msg) (s : Session Model Msg) (r : Request)
    (hseq : r.seq = s.seq)
    (hadv : s.lastView.toWire.advertises r.path r.event = true) :
    ∃ w, (s.handle app r).2 = .view (s.seq + 1) w := by
  have hd := (Html.advertises_iff _ _ _).1 hadv
  unfold Html.dispatch at hd
  unfold Session.handle
  split
  · exact absurd hseq ‹_›
  · split
    · rename_i hat; simp [hat] at hd
    · split
      · rename_i hat _ hh; simp [hat, hh] at hd
      · exact ⟨_, rfl⟩

/-- The view the client is looking at is the view of the current model. -/
def Session.Coherent (app : App Model Msg) (s : Session Model Msg) : Prop :=
  s.lastView = app.view s.model

theorem Session.start_coherent (app : App Model Msg) : (Session.start app).Coherent app := rfl

theorem Session.handle_coherent {app : App Model Msg} {s : Session Model Msg} {r : Request}
    (h : s.Coherent app) : (s.handle app r).1.Coherent app := by
  unfold Session.Coherent at h ⊢
  unfold Session.handle
  split
  · exact h
  · split
    · exact h
    · split
      · exact h
      · rfl

theorem Session.handle_inv (app : App Model Msg) (s : Session Model Msg) (r : Request)
    (I : Model → Prop) (hI : ∀ msg m, I m → I (app.update msg m)) (h : I s.model) :
    I (s.handle app r).1.model := by
  unfold Session.handle
  split
  · exact h
  · split
    · exact h
    · split
      · exact h
      · exact hI _ _ h

theorem Session.run_inv (app : App Model Msg) (I : Model → Prop)
    (hI : ∀ msg m, I m → I (app.update msg m)) {s : Session Model Msg} (h : I s.model) :
    ∀ rs, I (s.run app rs).model := by
  intro rs
  induction rs generalizing s with
  | nil => exact h
  | cons r rs ih => exact ih (Session.handle_inv app s r I hI h)

end ElmLean

namespace ElmLean

variable {Model Msg : Type}

theorem Session.run_coherent (app : App Model Msg) {s : Session Model Msg} (h : s.Coherent app) :
    ∀ rs, (s.run app rs).Coherent app := by
  intro rs
  induction rs generalizing s with
  | nil => exact h
  | cons r rs ih => exact ih (Session.handle_coherent h)

/-- An in-sync request whose path and event dispatch to `msg` is answered by running `update msg`. -/
theorem Session.handle_dispatch (app : App Model Msg) (s : Session Model Msg) (r : Request) (msg : Msg)
    (hseq : r.seq = s.seq) (hd : s.lastView.dispatch r.path r.event = some msg) :
    s.handle app r =
      ({ seq := s.seq + 1, model := app.update msg s.model, lastView := app.view (app.update msg s.model) },
       .view (s.seq + 1) (app.view (app.update msg s.model)).toWire) := by
  unfold Html.dispatch at hd
  unfold Session.handle
  split
  · exact absurd hseq ‹_›
  · split
    · rename_i hat; simp [hat] at hd
    · split
      · rename_i hat _ hh; simp [hat, hh] at hd
      · rename_i _ hat _ m hh; simp [hat, hh] at hd; subst hd; rfl

end ElmLean
