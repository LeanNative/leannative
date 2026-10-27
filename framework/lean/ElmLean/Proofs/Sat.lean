import ElmLean.Proofs.Erase

/-! `Sat P h` (every handler in `h` yields a message satisfying `P`) is preserved
by descending into children and by dispatching along any path. -/

namespace ElmLean.Html

variable {msg : Type} {P : msg → Prop} {h : Html msg}

theorem Sat.children (hs : Sat P h) : ∀ c ∈ h.children, Sat P c := by
  induction hs <;> simp [Html.children] <;> assumption

theorem Sat.handle (hs : Sat P h) (e : Event) (m : msg) (hd : h.handle e = some m) : P m := by
  induction hs with
  | identified i h _ ih => exact ih (by simpa [Html.handle] using hd)
  | _ => cases e <;> simp [Html.handle] at hd <;> (try subst hd) <;>
    first | (apply_assumption <;> first | rfl | assumption) | solve_by_elim

theorem Sat.dispatch (p : List Nat) :
    ∀ (h : Html msg), Sat P h → ∀ e m, h.dispatch p e = some m → P m := by
  induction p with
  | nil => intro h hs e m hd; simp [Html.dispatch, at?] at hd; exact hs.handle e m hd
  | cons i p ih =>
    intro h hs e m hd; rw [dispatch_cons] at hd
    cases hc : h.children[i]? with
    | none => simp [hc] at hd
    | some c => simp [hc] at hd; exact ih c (hs.children c (List.mem_of_getElem? hc)) e m hd

end ElmLean.Html
