namespace ElmLean

/-- An event a client can send back for a node. `input` and `toggle` carry the
full new value, never a delta. -/
inductive Event where
  | click
  | input (s : String)
  | submit
  | toggle (b : Bool)
  /-- A choice by index: a tab, a picker option, a stepper value. -/
  | select (n : Nat)
  /-- Back from a screen, or a sheet swiped away. -/
  | dismiss
  deriving Repr, DecidableEq

end ElmLean
