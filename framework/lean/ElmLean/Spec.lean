import ElmLean.Program

/-! # What an app author proves

A `Spec app` bundles the three obligations of a verified ElmLean app:

* `Inv` holds for the initial model (`init_inv`);
* every message preserves `Inv` (`update_inv`);
* in every model satisfying `Inv`, every handler of the view yields a message satisfying
  `Target m` (`view_sat`), the app's notion of "a message that makes sense in this model"
  (for the todo example: "any id it names belongs to an existing todo").

From those, `ElmLean/Proofs/Spec.lean` derives the whole-run guarantees for every session the CLI
can ever reach (`Spec.reachable_inv`, `Spec.reachable_sound`), with no further work by the author.
`Target` may be `fun _ _ => True` when there is nothing to say; `Html.Sat.of_forall` then
discharges `view_sat`. -/

namespace ElmLean

structure Spec {Model Msg : Type} (app : App Model Msg) where
  Inv : Model → Prop
  Target : Model → Msg → Prop
  init_inv : Inv app.init
  update_inv : ∀ msg m, Inv m → Inv (app.update msg m)
  view_sat : ∀ m, Inv m → Html.Sat (Target m) (app.view m)

/-- The session the CLI is in after answering the request trace `rs` from a fresh start. -/
def Session.reach {Model Msg : Type} (app : App Model Msg) (rs : List Request) : Session Model Msg :=
  (Session.start app).run app rs

end ElmLean
