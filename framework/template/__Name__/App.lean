import ElmLean.Program

/-! # __Name__

A starter app: a counter and a list of items typed into a field. Replace it with yours.

Write it in the subset `elmgen` translates to Swift: structures, inductives with payloads,
`List`/`String`/`Nat`/`Bool`/`Option`, `match` and `if` on app types, `List.map`/`filter`/`length`/`any`/`++`,
string interpolation, the `Html` constructors, named helper functions (no recursion, no `where`, no
lambdas returning `Html`). `elmgen` stops with the construct named on anything else. Every constant the
app reaches must live in the `__Name__` namespace. -/

namespace __Name__
open ElmLean

structure Model where
  count : Nat
  draft : String
  items : List String
  deriving Repr, Inhabited

inductive Msg where
  | inc
  | setDraft (s : String)
  | add
  | clear
  deriving Repr, DecidableEq

def Model.init : Model := ⟨0, "", []⟩

/-- The one `String.Slice` shape the translator understands. -/
def trimmed (s : String) : String := s.trimAscii.copy

def update : Msg → Model → Model
  | .inc, m => { m with count := m.count + 1 }
  | .setDraft s, m => { m with draft := s }
  | .add, m =>
    if (trimmed m.draft).isEmpty then m
    else { m with items := m.items ++ [trimmed m.draft], draft := "" }
  | .clear, m => { m with count := 0, items := [] }

def itemRow (s : String) : Html Msg := .text s .body

/-- Paths: [0] title · [1,{0 count, 1 "+1"}] · [2,{0 field, 1 Add}] · [3,i] items · [4] Clear. -/
def view (m : Model) : Html Msg :=
  .col [ .text "__Name__" .title
       , .row [ .text s!"{m.count}" .body, .button "+1" .primary (some .inc) ]
       , .row [ .field "New item" m.draft .setDraft (some .add)
              , .button "Add" .primary (if (trimmed m.draft).isEmpty then none else some .add) ]
       , .col (m.items.map itemRow)
       , .button "Clear" .destructive (if m.count = 0 ∧ m.items.length = 0 then none else some .clear) ]

/-- The app value: what the CLI serves, what the theorems are about, what `elmgen` translates. -/
def app : App Model Msg := ⟨Model.init, update, view⟩

end __Name__
