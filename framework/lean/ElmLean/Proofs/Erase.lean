import ElmLean.Erase

/-! Theorems about handler erasure: the wire tree advertises exactly the
`(path, event)` pairs whose dispatch produces a message. -/

namespace ElmLean.Html

variable {msg : Type}

theorem children_toWire (h : Html msg) : (toWire h).children = h.children.map toWire := by
  cases h with
  | identified i h => simpa [toWire, children, Wire.children] using children_toWire h
  | decorated d h => simpa [toWire, children, Wire.children] using children_toWire h
  | _ => simp [toWire, children, Wire.children]

theorem at?_toWire (p : List Nat) :
    ∀ (h : Html msg), (toWire h).at? p = (h.at? p).map toWire := by
  induction p with
  | nil => intro h; simp [at?, Wire.at?]
  | cons i p ih =>
    intro h
    simp only [at?, Wire.at?, children_toWire, List.getElem?_map]
    cases h.children[i]? <;> simp [ih]

theorem accepts_handle (n : Html msg) (e : Event) :
    (toWire n).accepts e = true ↔ (n.handle e).isSome := by
  cases n with
  | identified i n => simpa [toWire, Wire.accepts, handle] using accepts_handle n e
  | decorated d n => simpa [toWire, Wire.accepts, handle] using accepts_handle n e
  | _ => cases e <;> simp [toWire, Wire.accepts, handle]

/-- END-TO-END: the wire advertises `(p, e)` iff dispatching it yields a message. -/
theorem advertises_iff (h : Html msg) (p : List Nat) (e : Event) :
    (toWire h).advertises p e = true ↔ (h.dispatch p e).isSome := by
  unfold Wire.advertises dispatch
  rw [at?_toWire]
  cases h.at? p with
  | none => simp
  | some n => simp [accepts_handle]

theorem dispatch_cons (h : Html msg) (i : Nat) (p : List Nat) (e : Event) :
    h.dispatch (i :: p) e = h.children[i]? >>= (·.dispatch p e) := by
  simp only [dispatch, at?]; cases h.children[i]? <;> simp

end ElmLean.Html
