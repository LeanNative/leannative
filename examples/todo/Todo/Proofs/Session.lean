import ElmLean.Proofs.Spec
import Todo.App
import Todo.Proofs.Update
import Todo.Proofs.View

/-! The framework's session theorems applied to the Todo app, through its `Spec`. -/

namespace Todo
open ElmLean

/-- The three obligations of a verified ElmLean app, discharged for Todo. -/
def spec : Spec app where
  Inv := Model.Inv
  Target := WellTargeted
  init_inv := init_inv
  update_inv := fun msg m hm => update_inv msg m hm
  view_sat := fun m _ => view_sat m

theorem todo_start_inv : (Session.start app).model.Inv := init_inv

theorem todo_handle_inv (s : Session Model Msg) (r : Request) :
    s.model.Inv → ((s.handle app r).1).model.Inv :=
  fun h => Session.handle_inv app s r Model.Inv (fun msg m hm => update_inv msg m hm) h

/-- The whole-run claim: the model invariant holds after any request trace. -/
theorem todo_run_inv : ∀ rs, ((Session.start app).run app rs).model.Inv :=
  spec.reachable_inv

/-- For a coherent session, an advertised request with the right `seq` dispatches to a
message whose ids all belong to existing todos. -/
theorem todo_advertised_ok (s : Session Model Msg) (r : Request) :
    s.Coherent app → r.seq = s.seq →
    s.lastView.toWire.advertises r.path r.event = true →
    ∃ msg, s.lastView.dispatch r.path r.event = some msg ∧ WellTargeted s.model msg := by
  intro hc _ hadv
  unfold Session.Coherent at hc
  rw [hc] at hadv ⊢
  exact view_sound s.model r.path r.event hadv

/-- End to end, for every session the CLI can reach: an in-sync request for any advertised control
is answered by running `update` on a well-targeted message (`Spec.reachable_sound`). -/
theorem todo_reachable_sound (rs : List Request) (r : Request)
    (hseq : r.seq = (Session.reach app rs).seq)
    (hadv : (Session.reach app rs).lastView.toWire.advertises r.path r.event = true) :
    ∃ msg, (Session.reach app rs).lastView.dispatch r.path r.event = some msg
      ∧ WellTargeted (Session.reach app rs).model msg
      ∧ ((Session.reach app rs).handle app r).1.model = update msg (Session.reach app rs).model := by
  obtain ⟨msg, hd, ht, hm, _⟩ := spec.reachable_sound rs r hseq hadv
  exact ⟨msg, hd, ht, hm⟩

end Todo
