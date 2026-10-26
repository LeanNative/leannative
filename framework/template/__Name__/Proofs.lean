import ElmLean.Proofs.Spec
import __Name__.App

/-! What is proven about __Name__. A `Spec` is three obligations (`init_inv`, `update_inv`,
`view_sat`); the framework turns them into whole-run guarantees (`Spec.reachable_inv`,
`Spec.reachable_sound`) for every session the CLI can reach. -/

namespace __Name__
open ElmLean

/-- `+1` raises the count by exactly one. -/
theorem count_inc (m : Model) : (update .inc m).count = m.count + 1 := by
  simp [update]

/-- The invariant: no stored item is empty. -/
def Model.Inv (m : Model) : Prop := ∀ s ∈ m.items, s.isEmpty = false

theorem init_inv : Model.init.Inv := by
  intro s hs; simp [Model.init] at hs

theorem update_inv (msg : Msg) (m : Model) (h : m.Inv) : (update msg m).Inv := by
  cases msg with
  | inc => exact h
  | setDraft _ => exact h
  | add =>
    simp only [update]
    split
    · exact h
    · rename_i hne
      intro s hs
      simp only [List.mem_append, List.mem_singleton] at hs
      rcases hs with hs | rfl
      · exact h s hs
      · simpa using hne
  | clear => intro s hs; simp [update] at hs

/-- __Name__'s `Spec`. `Target` is trivial here; make it say what a sensible message is in your app
(see examples/todo: every id a message names belongs to an existing todo). -/
def spec : Spec app where
  Inv := Model.Inv
  Target := fun _ _ => True
  init_inv := init_inv
  update_inv := update_inv
  view_sat := fun _ _ => Html.Sat.of_forall (fun _ => trivial) _

/-- After any request trace, no stored item is empty. -/
theorem run_inv (rs : List Request) : (Session.reach app rs).model.Inv :=
  spec.reachable_inv rs

end __Name__
