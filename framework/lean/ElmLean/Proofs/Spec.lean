import ElmLean.Spec
import ElmLean.Proofs.Program
import ElmLean.Proofs.Sat

/-! # The guarantees a `Spec` buys, for every app

For any app with a `S : Spec app` and any request trace `rs`, the session `Session.reach app rs`
the CLI is in afterwards satisfies the invariant (`reachable_inv`) and shows the view of its model
(`Session.reach_coherent`). An in-sync request for any control that view advertises is answered with
a fresh view, by running `update` on a message that satisfies `Target` in the current model
(`reachable_sound`). -/

namespace ElmLean

variable {Model Msg : Type}

/-- If every message satisfies `P`, every tree satisfies `Sat P` (for `Target := fun _ _ => True`). -/
theorem Html.Sat.of_forall {P : Msg → Prop} (hP : ∀ m, P m) : ∀ h : Html Msg, Html.Sat P h
  | .text s st => .text s st
  | .divider => .divider
  | .spacer => .spacer
  | .col cs => .col cs fun c _ => Html.Sat.of_forall hP c
  | .row cs => .row cs fun c _ => Html.Sat.of_forall hP c
  | .button l r c => .button l r c fun m _ => hP m
  | .field pl v f s => .field pl v f s (fun _ => hP _) (fun m _ => hP m)
  | .toggle l on f => .toggle l on f fun _ => hP _
  | .input k l pl v f s => .input k l pl v f s (fun _ => hP _) (fun m _ => hP m)
  | .list cs => .list cs fun c _ => Html.Sat.of_forall hP c
  | .section h f cs => .section h f cs fun c _ => Html.Sat.of_forall hP c
  | .labeled l v => .labeled l v
  | .screen t b cs r lt => .screen t b cs r lt (fun m _ => hP m) (fun m _ => hP m) fun c _ => Html.Sat.of_forall hP c
  | .toolbar cs p => .toolbar cs p fun c _ => Html.Sat.of_forall hP c
  | .tabs ls is sel f cs => .tabs ls is sel f cs (fun _ => hP _) fun c _ => Html.Sat.of_forall hP c
  | .sheet t d cs lt => .sheet t d cs lt (fun m _ => hP m) fun c _ => Html.Sat.of_forall hP c
  | .alert t m cs => .alert t m cs fun c _ => Html.Sat.of_forall hP c
  | .picker l os sel f => .picker l os sel f fun _ => hP _
  | .progress l => .progress l
  | .icon n => .icon n
  | .qr t => .qr t
  | .share l t f => .share l t f
  | .link l u => .link l u
  | .page p => .page p
  | .empty t i m cs => .empty t i m cs fun c _ => Html.Sat.of_forall hP c
  | .disclosure t e f cs => .disclosure t e f cs (fun _ => hP _) fun c _ => Html.Sat.of_forall hP c
  | .stepper l v lo hi f d => .stepper l v lo hi f d fun _ => hP _
  | .identified i h => .identified i h (Html.Sat.of_forall hP h)
  | .decorated d h => .decorated d h (Html.Sat.of_forall hP h)

/-- Every reachable session shows the view of its model. -/
theorem Session.reach_coherent (app : App Model Msg) (rs : List Request) :
    (Session.reach app rs).Coherent app :=
  Session.run_coherent app (Session.start_coherent app) rs

namespace Spec

variable {app : App Model Msg} (S : Spec app)

theorem reachable_inv (rs : List Request) : S.Inv (Session.reach app rs).model :=
  Session.run_inv app S.Inv S.update_inv S.init_inv rs

/-- The end-to-end statement: after any trace, an in-sync request for an advertised control
dispatches to a message satisfying `Target`, and the CLI answers it by running `update` on exactly
that message and replying with the new view at `seq + 1`. -/
theorem reachable_sound (rs : List Request) (r : Request)
    (hseq : r.seq = (Session.reach app rs).seq)
    (hadv : (Session.reach app rs).lastView.toWire.advertises r.path r.event = true) :
    ∃ msg, (Session.reach app rs).lastView.dispatch r.path r.event = some msg
      ∧ S.Target (Session.reach app rs).model msg
      ∧ ((Session.reach app rs).handle app r).1.model = app.update msg (Session.reach app rs).model
      ∧ ((Session.reach app rs).handle app r).2 =
          .view ((Session.reach app rs).seq + 1)
            (app.view (app.update msg (Session.reach app rs).model)).toWire := by
  have hc := Session.reach_coherent app rs
  unfold Session.Coherent at hc
  obtain ⟨msg, hd⟩ := Option.isSome_iff_exists.1 ((Html.advertises_iff _ _ _).1 hadv)
  have ht : S.Target (Session.reach app rs).model msg := by
    have hsat := S.view_sat _ (S.reachable_inv rs)
    rw [← hc] at hsat
    exact Html.Sat.dispatch r.path _ hsat r.event msg hd
  refine ⟨msg, hd, ht, ?_, ?_⟩ <;> rw [Session.handle_dispatch app _ r msg hseq hd]

end Spec
end ElmLean
