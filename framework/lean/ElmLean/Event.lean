namespace ElmLean

/-- An event a client can send back for a node. `input` and `toggle` carry the
full new value, never a delta. -/
inductive Event where
  | click
  | input (s : String)
  | submit
  | toggle (b : Bool)
  deriving Repr, DecidableEq

end ElmLean
