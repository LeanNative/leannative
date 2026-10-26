import ElmLean.Event

namespace ElmLean

inductive TextStyle where
  | title
  | body
  | caption
  deriving Repr, DecidableEq, Inhabited

inductive ButtonRole where
  | plain
  | primary
  | destructive
  deriving Repr, DecidableEq, Inhabited

/-- The UI language. A `view : Model → Html Msg` can only emit messages of type
`Msg`, so by construction every event the UI can produce is one `update` handles.
Interactive nodes carry their handlers; `Html.toWire` erases them for the wire. -/
inductive Html (msg : Type) where
  | text (s : String) (style : TextStyle)
  | col (children : List (Html msg))
  | row (children : List (Html msg))
  /-- `onClick = none` renders as a disabled button. -/
  | button (label : String) (role : ButtonRole) (onClick : Option msg)
  /-- `onSubmit = none` means the return key does nothing. -/
  | field (placeholder value : String) (onInput : String → msg) (onSubmit : Option msg)
  | toggle (label : String) (on : Bool) (onToggle : Bool → msg)
  | divider
  | spacer

namespace Html

variable {msg : Type}

/-- Children of a node (only `col`/`row` have any). Written with one equation per
constructor so that `simp [children]` always fires. -/
def children : Html msg → List (Html msg)
  | .col cs => cs
  | .row cs => cs
  | .text .. => []
  | .button .. => []
  | .field .. => []
  | .toggle .. => []
  | .divider => []
  | .spacer => []

/-- The node at a path of child indices. -/
def at? : Html msg → List Nat → Option (Html msg)
  | h, [] => some h
  | h, i :: p => h.children[i]? >>= (at? · p)

/-- Apply an event to a single node. -/
def handle : Html msg → Event → Option msg
  | .button _ _ c, .click => c
  | .field _ _ f _, .input s => some (f s)
  | .field _ _ _ s, .submit => s
  | .toggle _ _ f, .toggle b => some (f b)
  | _, _ => none

/-- Dispatch an event addressed by path. -/
def dispatch (h : Html msg) (p : List Nat) (e : Event) : Option msg :=
  h.at? p >>= (·.handle e)

def countToggles : Html msg → Nat
  | .col cs => (cs.map countToggles).sum
  | .row cs => (cs.map countToggles).sum
  | .toggle .. => 1
  | _ => 0

def toggleLabels : Html msg → List String
  | .col cs => (cs.map toggleLabels).flatten
  | .row cs => (cs.map toggleLabels).flatten
  | .toggle l _ _ => [l]
  | _ => []

/-- Every handler anywhere in the tree produces a message satisfying `P`. -/
inductive Sat (P : msg → Prop) : Html msg → Prop
  | text (s : String) (st : TextStyle) : Sat P (.text s st)
  | divider : Sat P .divider
  | spacer : Sat P .spacer
  | col (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.col cs)
  | row (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.row cs)
  | button (l : String) (r : ButtonRole) (c : Option msg) :
      (∀ m, c = some m → P m) → Sat P (.button l r c)
  | field (pl v : String) (f : String → msg) (s : Option msg) :
      (∀ str, P (f str)) → (∀ m, s = some m → P m) → Sat P (.field pl v f s)
  | toggle (l : String) (on : Bool) (f : Bool → msg) :
      (∀ b, P (f b)) → Sat P (.toggle l on f)

end Html
end ElmLean
