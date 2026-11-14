import LeanNative.Event

namespace LeanNative

inductive TextStyle where
  /-- a heading (Title 2, bold) -/
  | title
  | body
  /-- small secondary text (Caption 1) -/
  | caption
  -- native mode: the rest of the system's text styles
  /-- the largest (Large Title, bold): a headline number -/
  | largeTitle
  | title3
  | headline
  | subheadline
  | callout
  /-- explanations under a control or in a section footer -/
  | footnote
  /-- the smallest secondary text (Caption 2) -/
  | caption2
  deriving Repr, DecidableEq, Inhabited

/-- A colour by meaning (native mode, `Decor.tone`); `standard` keeps the node's own. -/
inductive Tone where
  | standard
  | secondary
  /-- the app's tint -/
  | tint
  /-- green: money in, success -/
  | positive
  /-- red: money out, failure -/
  | negative
  /-- orange: a caution -/
  | warning
  deriving Repr, DecidableEq, Inhabited

/-- A button that is a list row's swipe action (native mode, `Decor.swipe`): the edge it is swiped in from.
`none` is an ordinary button. -/
inductive Swipe where
  | none
  /-- swiped in from the row's leading edge -/
  | leading
  /-- swiped in from the row's trailing edge -/
  | trailing
  deriving Repr, DecidableEq, Inhabited

/-- Where a `toolbar`'s buttons go (native mode): the navigation bar's `trailing` or `leading` end, `cancel`
(leading; a `cancel`-role button there is the system Close button), `confirm` (trailing, prominent), or the
`bottom` toolbar. -/
inductive Placement where
  | trailing
  | leading
  | cancel
  | confirm
  | bottom
  deriving Repr, DecidableEq, Inhabited

/-- How tall a sheet opens (native mode): `large` (the full sheet), or `medium` (half the screen, with a
grabber to pull it up to large). -/
inductive SheetSize where
  | large
  | medium
  deriving Repr, DecidableEq, Inhabited

/-- How an `alert` is presented (native mode): a centred alert, or an action sheet (a confirmation dialog,
anchored to the control that asked). -/
inductive AlertStyle where
  | alert
  | actionSheet
  deriving Repr, DecidableEq, Inhabited

/-- How a node looks beyond its kind (native mode, `Html.decorated`). Every default changes nothing, so a
shell that does not know a field shows the node as before. -/
structure Decor where
  tone : Tone := .standard
  /-- monospaced text, wrapped at any character (addresses, txids, descriptors) -/
  mono : Bool := false
  /-- a text as a small capsule badge, in its tone -/
  badge : Bool := false
  /-- centred text (under a QR code, say) -/
  centered : Bool := false
  /-- A column in a neutral panel with a left accent rule. Its children, identifiers and events stay
  unchanged. Other node kinds ignore it. A shell without support draws the ordinary column. -/
  callout : Bool := false
  /-- an SF Symbols name drawn before a button's or a labeled row's label, or a text -/
  symbol : String := ""
  /-- the button opens something (a screen, a sheet): drawn as a link, and in a list its whole row is the
  button, with a disclosure chevron -/
  chevron : Bool := false
  /-- a button inside a list's row is not drawn in the row: it is the row's swipe action on that edge, with
  its label, its `symbol`, its tone's or its role's colour and its click (a mail row's Done, Snooze). In the
  tree's order, the first is nearest the edge and is what a full swipe does; a disabled button is no action.
  Outside a list's row, and in a shell that does not know the field, it is the button it was. -/
  swipe : Swipe := .none
  /-- a list's row is the one chosen (the mailbox whose mail is listed, the message being read): drawn as the
  platform's selection, and read as selected. On the row's own node. -/
  selected : Bool := false
  /-- a button inside a list's row is an item of the row's context menu: a right click on a Mac, a long press on a
  phone. The item has the button's label, its `symbol` and its click, red when the button is `destructive` and
  greyed when it is disabled, in the tree's order. A button that is only a menu item is not drawn in its row, as
  a swipe action is not; one button may be both. Outside a list's row, and in a shell that does not know the
  field, it is the button it was. -/
  menu : Bool := false
  /-- a key equivalent, for a keyboard: `"cmd+r"`, `"cmd+shift+n"`, `"ctrl+cmd+a"`, `"escape"`. The modifiers
  `cmd`, `shift`, `alt` and `ctrl`, joined with `+`, then one key: a character, or `return`, `escape`, `tab`,
  `space`, `delete`, `up`, `down`, `left`, `right`. Pressed, it is the node's `click`: an enabled button's, or a
  screen's pull to refresh. On an `input` or a `field`, which has no click, it puts the cursor in it. A key
  reaches what is on top: with a sheet up only the sheet's nodes, with an alert up none. A Mac lists the keys in
  its menu bar, each under its node's label. A key with neither `cmd` nor `ctrl` is text while a field is being
  typed in, and does nothing then. The shell has two keys of its own, which an app's same key replaces: `cmd+[`
  goes back from a screen and `escape` closes a sheet. -/
  key : String := ""
  /-- a button inside a list's row is what a click on the row does with a modifier key held: `"cmd"` (the
  command key, or control) or `"shift"`. The click is the button's own, so `update` hears the message it
  already has for it; a disabled one does nothing, and the row's plain click is not done then. Such a button
  is not drawn in its row, as a swipe action is not. What a list does with it is the app's: picking a row
  beside the others, picking a run of rows. Outside a list's row, and in a shell that does not know the field,
  it is the button it was; with a finger there is no modifier, and the row's click is the plain one. -/
  pointer : String := ""
  deriving Repr, DecidableEq, Inhabited

/-- `outer`'s fields where they are set, else `inner`'s. -/
def Decor.merge (inner outer : Decor) : Decor :=
  { tone := if outer.tone == .standard then inner.tone else outer.tone
    mono := inner.mono || outer.mono
    badge := inner.badge || outer.badge
    centered := inner.centered || outer.centered
    callout := inner.callout || outer.callout
    symbol := if outer.symbol.isEmpty then inner.symbol else outer.symbol
    chevron := inner.chevron || outer.chevron
    swipe := if outer.swipe == .none then inner.swipe else outer.swipe
    selected := inner.selected || outer.selected
    menu := inner.menu || outer.menu
    key := if outer.key.isEmpty then inner.key else outer.key
    pointer := if outer.pointer.isEmpty then inner.pointer else outer.pointer }

inductive ButtonRole where
  | plain
  | primary
  | destructive
  -- native mode
  /-- a side action beside a primary one (tinted; Liquid Glass on iOS 26) -/
  | secondary
  /-- dismisses without doing anything: an alert's Cancel, a sheet's close control in its toolbar -/
  | cancel
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
  -- The constructors below came with the native shell (framework/native).
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
  to the navigation bar. Native mode: `largeTitle` (a large title that collapses as the page scrolls), and
  `depth`, the screen's place in its navigation stack (0 the root; a screen with `onBack` is at least 1): a
  deeper screen than the one shown is pushed, a shallower one pops back to it, and the system back button or
  an edge swipe pops it and sends `dismiss`. -/
  | screen (title : String) (onBack : Option msg) (children : List (Html msg)) (onRefresh : Option msg := none)
      (largeTitle : Bool := true) (depth : Nat := 0)
  /-- Buttons for the navigation bar of the enclosing screen. -/
  | toolbar (children : List (Html msg)) (placement : Placement := .trailing)
  /-- A tab bar: one label and icon per tab, the selected index, and the selected tab's content. -/
  | tabs (labels icons : List String) (selected : Nat) (onSelect : Nat → msg) (children : List (Html msg))
  /-- Columns side by side where the window is wide enough: a sidebar, then a list, then what the list's choice
  shows (two children: a sidebar and its content). Each child is a `screen`, with its own title and `toolbar`.
  Where the window is too narrow for them (a phone, a narrow Mac or iPad window) one column shows at a time,
  `shown` naming which (the child's index), and going back from it sends that screen's `dismiss`. Only at the
  root, as `tabs` is. -/
  | split (shown : Nat) (children : List (Html msg))
  /-- A sheet presented over the screen; `onDismiss = none` cannot be swiped away. -/
  | sheet (title : String) (onDismiss : Option msg) (children : List (Html msg)) (largeTitle : Bool := false)
      (size : SheetSize := .large)
  /-- An alert; its children are its buttons (a `cancel`-role one is its Cancel, a `primary` one its preferred
  action). -/
  | alert (title message : String) (children : List (Html msg)) (style : AlertStyle := .alert)
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
  /-- `child` with an identifier for UI tests (the shell's `accessibilityIdentifier`). It is not a node of
  its own: it has `child`'s children and handlers, so paths and events pass through it, and on the wire it
  is `child`'s object with an `"id"` key. -/
  | identified (id : String) (child : Html msg)
  /-- `child` drawn with `d` (native mode): like `identified` not a node of its own, so paths and events pass
  through it; on the wire it is `child`'s object with a `"decor"` object. -/
  | decorated (d : Decor) (child : Html msg)

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
  | .screen _ _ cs _ _ _ => cs
  | .toolbar cs _ => cs
  | .tabs _ _ _ _ cs => cs
  | .split _ cs => cs
  | .sheet _ _ cs _ _ => cs
  | .alert _ _ cs _ => cs
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
  | .identified _ h => h.children
  | .decorated _ h => h.children

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
  | .screen _ b _ _ _ _, .dismiss => b
  | .screen _ _ _ r _ _, .click => r
  | .tabs _ _ _ f _, .select n => some (f n)
  | .sheet _ d _ _ _, .dismiss => d
  | .picker _ _ _ f, .select n => some (f n)
  | .disclosure _ _ f _, .toggle b => some (f b)
  | .stepper _ _ _ _ f _, .select n => some (f n)
  | .identified _ h, e => h.handle e
  | .decorated _ h, e => h.handle e
  | _, _ => none

/-- Dispatch an event addressed by path. -/
def dispatch (h : Html msg) (p : List Nat) (e : Event) : Option msg :=
  h.at? p >>= (·.handle e)

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
  | screen (t : String) (b : Option msg) (cs : List (Html msg)) (r : Option msg) (lt : Bool) (d : Nat) :
      (∀ m, b = some m → P m) → (∀ m, r = some m → P m) → (∀ c ∈ cs, Sat P c) → Sat P (.screen t b cs r lt d)
  | toolbar (cs : List (Html msg)) (p : Placement) : (∀ c ∈ cs, Sat P c) → Sat P (.toolbar cs p)
  | tabs (ls is : List String) (sel : Nat) (f : Nat → msg) (cs : List (Html msg)) :
      (∀ n, P (f n)) → (∀ c ∈ cs, Sat P c) → Sat P (.tabs ls is sel f cs)
  | split (sh : Nat) (cs : List (Html msg)) : (∀ c ∈ cs, Sat P c) → Sat P (.split sh cs)
  | sheet (t : String) (d : Option msg) (cs : List (Html msg)) (lt : Bool) (sz : SheetSize) :
      (∀ m, d = some m → P m) → (∀ c ∈ cs, Sat P c) → Sat P (.sheet t d cs lt sz)
  | alert (t m : String) (cs : List (Html msg)) (st : AlertStyle) : (∀ c ∈ cs, Sat P c) → Sat P (.alert t m cs st)
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
  | identified (i : String) (h : Html msg) : Sat P h → Sat P (.identified i h)
  | decorated (d : Decor) (h : Html msg) : Sat P h → Sat P (.decorated d h)

/-- `h` drawn with `d` as well: merged into a decoration `h` already has (through an identifier), so
decorations compose (`(body s).tone .positive |>.mono`). -/
def decor (d : Decor) : Html msg → Html msg
  | .decorated d' h => .decorated (d'.merge d) h
  | .identified i h => .identified i (decor d h)
  | h => .decorated d h

def tone (t : Tone) (h : Html msg) : Html msg := decor { tone := t } h
def mono (h : Html msg) : Html msg := decor { mono := true } h
def badge (h : Html msg) : Html msg := decor { badge := true } h
def centered (h : Html msg) : Html msg := decor { centered := true } h
/-- A padded column with a left accent rule; its tone colours the rule, not the children's text. -/
def callout (children : List (Html msg)) : Html msg := decor { callout := true } (.col children)
def symbol (name : String) (h : Html msg) : Html msg := decor { symbol := name } h
def navigates (h : Html msg) : Html msg := decor { chevron := true } h
/-- A button as its list row's swipe action on `edge` (`Decor.swipe`). -/
def swipe (edge : Swipe) (h : Html msg) : Html msg := decor { swipe := edge } h
/-- A list's row as the chosen one when `on` (`Decor.selected`). -/
def chosen (on : Bool) (h : Html msg) : Html msg := if on then decor { selected := true } h else h
/-- A button as an item of its list row's context menu (`Decor.menu`). -/
def inMenu (h : Html msg) : Html msg := decor { menu := true } h
/-- A node with a key equivalent (`Decor.key`): `(button …).key "cmd+r"`. -/
def key (k : String) (h : Html msg) : Html msg := decor { key := k } h
/-- A button in a list's row as the row's click with a modifier key held (`Decor.pointer`): `"cmd"` or
`"shift"`. -/
def onClickWith (modifier : String) (h : Html msg) : Html msg := decor { pointer := modifier } h

end Html
end LeanNative
