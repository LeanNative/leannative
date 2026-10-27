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

/-- What a text input is for (native mode): the renderer picks the control and keyboard. -/
inductive InputKind where
  | plain
  | secure
  | multiline
  | number
  /-- digits and a decimal separator (a fee rate) -/
  | decimal
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
  -- The constructors below are rendered by the native-mode shell (framework/native); `elmgen` does
  -- not translate them.
  /-- A labelled text input; `onSubmit = none` means the return key does nothing. -/
  | input (kind : InputKind) (label placeholder value : String) (onInput : String → msg) (onSubmit : Option msg)
  /-- A grouped list (a SwiftUI `Form`). -/
  | list (children : List (Html msg))
  /-- A section of a grouped list, with optional header and footer text. -/
  | section (header footer : String) (children : List (Html msg))
  /-- A label and a value on one line. -/
  | labeled (label value : String)
  /-- A navigation screen: a title, a back control when `onBack` is some (event `dismiss`), the content, and
  pull-to-refresh when `onRefresh` is some (event `click` on the screen). A `toolbar` among the children goes
  to the navigation bar. -/
  | screen (title : String) (onBack : Option msg) (children : List (Html msg)) (onRefresh : Option msg := none)
  /-- Buttons for the navigation bar of the enclosing screen. -/
  | toolbar (children : List (Html msg))
  /-- A tab bar: one label and icon per tab, the selected index, and the selected tab's content. -/
  | tabs (labels icons : List String) (selected : Nat) (onSelect : Nat → msg) (children : List (Html msg))
  /-- A sheet presented over the screen; `onDismiss = none` cannot be swiped away. -/
  | sheet (title : String) (onDismiss : Option msg) (children : List (Html msg))
  /-- An alert; its children are its buttons. -/
  | alert (title message : String) (children : List (Html msg))
  /-- A choice among labelled options (event `select i`). -/
  | picker (label : String) (options : List String) (selected : Nat) (onSelect : Nat → msg)
  /-- A spinner with a caption. -/
  | progress (label : String)
  /-- A symbol (an SF Symbols name). -/
  | icon (name : String)
  /-- A QR code of the text. -/
  | qr (text : String)
  /-- A share button for the text, or for the file at path `text` when `file` (the share sheet offers Save to
  Files with the file's name). -/
  | share (label text : String) (file : Bool := false)
  /-- A link that opens the URL outside the app. -/
  | link (label url : String)
  /-- A bundled HTML page (path inside the app bundle), shown with scripts and networking off. -/
  | page (path : String)
  /-- An empty state: title, symbol, message, and its actions as children. -/
  | empty (title icon message : String) (children : List (Html msg))
  /-- A disclosure group; expanding or collapsing is a `toggle` event. -/
  | disclosure (title : String) (expanded : Bool) (onToggle : Bool → msg) (children : List (Html msg))
  /-- A stepper over `lo…hi` (event `select n`); `detail`, when set, is shown in place of the value (e.g. "2 of 3"). -/
  | stepper (label : String) (value lo hi : Nat) (onChange : Nat → msg) (detail : String := "")

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
  | .input .. => []
  | .list cs => cs
  | .section _ _ cs => cs
  | .labeled .. => []
  | .screen _ _ cs _ => cs
  | .toolbar cs => cs
  | .tabs _ _ _ _ cs => cs
  | .sheet _ _ cs => cs
  | .alert _ _ cs => cs
  | .picker .. => []
  | .progress .. => []
  | .icon .. => []
  | .qr .. => []
  | .share .. => []
  | .link .. => []
  | .page .. => []
  | .empty _ _ _ cs => cs
  | .disclosure _ _ _ cs => cs
  | .stepper .. => []

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
  | .input _ _ _ _ f _, .input s => some (f s)
  | .input _ _ _ _ _ s, .submit => s
  | .screen _ b _ _, .dismiss => b
  | .screen _ _ _ r, .click => r
  | .tabs _ _ _ f _, .select n => some (f n)
  | .sheet _ d _, .dismiss => d
  | .picker _ _ _ f, .select n => some (f n)
  | .disclosure _ _ f _, .toggle b => some (f b)
  | .stepper _ _ _ _ f _, .select n => some (f n)
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
  | input (k : InputKind) (l pl v : String) (f : String → msg) (s : Option msg) :
      (∀ str, P (f str)) → (∀ m, s = some m → P m) → Sat P (.input k l pl v f s)
  | list (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.list cs)
  | section (h f : String) (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.section h f cs)
  | labeled (l v : String) : Sat P (.labeled l v)
  | screen (t : String) (b : Option msg) (cs : List (Html msg)) (r : Option msg) :
      (∀ m, b = some m → P m) → (∀ m, r = some m → P m) → (∀ c ∈ cs, Sat P c) → Sat P (.screen t b cs r)
  | toolbar (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.toolbar cs)
  | tabs (ls is : List String) (sel : Nat) (f : Nat → msg) (cs : List (Html msg)) :
      (∀ n, P (f n)) → (∀ c ∈ cs, Sat P c) → Sat P (.tabs ls is sel f cs)
  | sheet (t : String) (d : Option msg) (cs : List (Html msg)) :
      (∀ m, d = some m → P m) → (∀ c ∈ cs, Sat P c) → Sat P (.sheet t d cs)
  | alert (t m : String) (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.alert t m cs)
  | picker (l : String) (os : List String) (sel : Nat) (f : Nat → msg) :
      (∀ n, P (f n)) → Sat P (.picker l os sel f)
  | progress (l : String) : Sat P (.progress l)
  | icon (n : String) : Sat P (.icon n)
  | qr (t : String) : Sat P (.qr t)
  | share (l t : String) (f : Bool) : Sat P (.share l t f)
  | link (l u : String) : Sat P (.link l u)
  | page (p : String) : Sat P (.page p)
  | empty (t i m : String) (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.empty t i m cs)
  | disclosure (t : String) (e : Bool) (f : Bool → msg) (cs : List (Html msg)) :
      (∀ b, P (f b)) → (∀ c ∈ cs, Sat P c) → Sat P (.disclosure t e f cs)
  | stepper (l : String) (v lo hi : Nat) (f : Nat → msg) (d : String) : (∀ n, P (f n)) → Sat P (.stepper l v lo hi f d)

end Html
end ElmLean
