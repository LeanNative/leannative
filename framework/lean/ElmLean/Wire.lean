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
  | input (kind : InputKind) (label placeholder value : String) (submits : Bool)
  | list (children : List Wire)
  | section (header footer : String) (children : List Wire)
  | labeled (label value : String)
  | screen (title : String) (back : Bool) (children : List Wire) (refreshable : Bool := false) (largeTitle : Bool := true)
  | toolbar (children : List Wire) (placement : Placement := .trailing)
  | tabs (labels icons : List String) (selected : Nat) (children : List Wire)
  | sheet (title : String) (dismissable : Bool) (children : List Wire) (largeTitle : Bool := false)
  | alert (title message : String) (children : List Wire)
  | picker (label : String) (options : List String) (selected : Nat)
  | progress (label : String)
  | icon (name : String)
  | qr (text : String)
  | share (label text : String) (file : Bool := false)
  | link (label url : String)
  | page (path : String)
  | empty (title icon message : String) (children : List Wire)
  | disclosure (title : String) (expanded : Bool) (children : List Wire)
  | stepper (label : String) (value lo hi : Nat) (detail : String := "")
  /-- `Html.identified`: `child` with an `"id"` key, its children and events its own -/
  | identified (id : String) (child : Wire)
  /-- `Html.decorated`: `child` with a `"decor"` object, its children and events its own -/
  | decorated (d : Decor) (child : Wire)
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
  | .input .. => []
  | .list cs => cs
  | .section _ _ cs => cs
  | .labeled .. => []
  | .screen _ _ cs _ _ => cs
  | .toolbar cs _ => cs
  | .tabs _ _ _ cs => cs
  | .sheet _ _ cs _ => cs
  | .alert _ _ cs => cs
  | .picker .. => []
  | .progress .. => []
  | .icon .. => []
  | .qr .. => []
  | .share .. => []
  | .link .. => []
  | .page .. => []
  | .empty _ _ _ cs => cs
  | .disclosure _ _ cs => cs
  | .stepper .. => []
  | .identified _ w => w.children
  | .decorated _ w => w.children

def at? : Wire → List Nat → Option Wire
  | w, [] => some w
  | w, i :: p => w.children[i]? >>= (at? · p)

/-- What a client is allowed to infer from a node alone: which event kinds it accepts. -/
def accepts : Wire → Event → Bool
  | .button _ _ en, .click => en
  | .field .., .input _ => true
  | .field _ _ s, .submit => s
  | .toggle .., .toggle _ => true
  | .input .., .input _ => true
  | .input _ _ _ _ s, .submit => s
  | .screen _ b _ _ _, .dismiss => b
  | .screen _ _ _ r _, .click => r
  | .tabs .., .select _ => true
  | .sheet _ d _ _, .dismiss => d
  | .picker .., .select _ => true
  | .disclosure .., .toggle _ => true
  | .stepper .., .select _ => true
  | .identified _ w, e => w.accepts e
  | .decorated _ w, e => w.accepts e
  | _, _ => false

/-- The wire tree advertises `(p, e)` when the node at `p` accepts `e`. -/
def advertises (w : Wire) (p : List Nat) (e : Event) : Bool :=
  match w.at? p with
  | some n => n.accepts e
  | none => false

end Wire
end ElmLean
