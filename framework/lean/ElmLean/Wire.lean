import ElmLean.Html

namespace ElmLean

/-- The view tree as it crosses the wire: `Html` with handlers erased to booleans. -/
inductive Wire where
  | text (s : String) (style : TextStyle)
  | col (children : List Wire)
  | row (children : List Wire)
  | button (label : String) (role : ButtonRole) (enabled : Bool)
  | field (placeholder value : String) (submits : Bool)
  | toggle (label : String) (on : Bool)
  | divider
  | spacer
  deriving Repr, Inhabited

namespace Wire

def children : Wire → List Wire
  | .col cs => cs
  | .row cs => cs
  | .text .. => []
  | .button .. => []
  | .field .. => []
  | .toggle .. => []
  | .divider => []
  | .spacer => []

def at? : Wire → List Nat → Option Wire
  | w, [] => some w
  | w, i :: p => w.children[i]? >>= (at? · p)

/-- What a client is allowed to infer from a node alone: which event kinds it accepts. -/
def accepts : Wire → Event → Bool
  | .button _ _ en, .click => en
  | .field .., .input _ => true
  | .field _ _ s, .submit => s
  | .toggle .., .toggle _ => true
  | _, _ => false

/-- The wire tree advertises `(p, e)` when the node at `p` accepts `e`. -/
def advertises (w : Wire) (p : List Nat) (e : Event) : Bool :=
  match w.at? p with
  | some n => n.accepts e
  | none => false

end Wire
end ElmLean
