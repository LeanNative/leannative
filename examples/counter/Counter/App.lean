import ElmLean.Program

/-! # Counter: the second ElmLean example

A counter with `+`/`-` buttons, a text field whose submit appends a note, a toggle and a Delete
button per note, an All/Pending filter pair, a Clear button and a caption.

Written in the restricted style the Lean → Swift translator accepts, so the native app is generated
from exactly these definitions: records, enums with payload, `List`/`String`/`Nat`/`Bool`/`Option`,
`if`/`match` on app types, `List.map`/`filter`/`length`/`any`/`++`, string interpolation and the
`Html` constructors, `Nat` subtraction (saturating, as in Lean); no recursion, no `where`. -/

namespace Counter
open ElmLean

/-- One note. `done` is set by the row's toggle (the toggle's value is authoritative, never a flip). -/
structure Note where
  id : Nat
  text : String
  done : Bool
  deriving Repr, DecidableEq, Inhabited

/-- Which notes the list shows. -/
inductive NoteFilter where
  | all
  | pending
  deriving Repr, DecidableEq, Inhabited

/-- The model. `count - 1` on a `Nat` truncates at zero in Lean; the translator prints it as
`max(count - 1, 0)`, so the generated app agrees. -/
structure Model where
  count : Nat
  draft : String
  notes : List Note
  nextId : Nat
  filter : NoteFilter
  deriving Repr, Inhabited

inductive Msg where
  | inc
  | dec
  | setDraft (s : String)
  | addNote
  /-- Set a note's done flag to the toggle's new value. -/
  | setDone (id : Nat) (done : Bool)
  | delete (id : Nat)
  | setFilter (f : NoteFilter)
  /-- Back to zero and no notes. -/
  | clear
  deriving Repr, DecidableEq

def Model.init : Model := ⟨0, "", [], 0, .all⟩

/-- `s.trimAscii.copy` is the one `String.Slice` shape the translator understands. -/
def trimNote (s : String) : String := s.trimAscii.copy

def setDoneIf (id : Nat) (b : Bool) (n : Note) : Note :=
  if n.id = id then { n with done := b } else n

def update : Msg → Model → Model
  | .inc, m => { m with count := m.count + 1 }
  | .dec, m => { m with count := m.count - 1 }
  | .setDraft s, m => { m with draft := s }
  | .addNote, m =>
    let text := trimNote m.draft
    if text.isEmpty then m
    else { m with notes := m.notes ++ [⟨m.nextId, text, false⟩], draft := "", nextId := m.nextId + 1 }
  | .setDone id b, m => { m with notes := m.notes.map (setDoneIf id b) }
  | .delete id, m => { m with notes := m.notes.filter (fun n => n.id != id) }
  | .setFilter f, m => { m with filter := f }
  | .clear, m => { m with count := 0, notes := [] }

/-- The notes shown under the current filter. -/
def visible (m : Model) : List Note :=
  match m.filter with
  | .all => m.notes
  | .pending => m.notes.filter (fun n => !n.done)

/-- How many notes are not done. -/
def pendingCount (m : Model) : Nat := (m.notes.filter (fun n => !n.done)).length

/-- One note row: toggle, spacer, Delete. -/
def noteRow (n : Note) : Html Msg :=
  .row [ .toggle n.text n.done (fun b => .setDone n.id b)
       , .spacer
       , .button "Delete" .destructive (some (.delete n.id)) ]

/-- A filter button is `primary` when it is the selected filter, `plain` otherwise. -/
def filterButton (m : Model) (f : NoteFilter) (label : String) : Html Msg :=
  .button label (if m.filter = f then .primary else .plain) (some (.setFilter f))

/-- Paths: [0] title · [1,{0 "-", 1 count, 2 "+"}] · [2,0] field · [2,1] Add
· [3,i,{0 toggle, 1 spacer, 2 Delete}] · [4] divider · [5,{0 All, 1 Pending}] · [6] caption · [7] Clear. -/
def view (m : Model) : Html Msg :=
  .col [ .text "Counter" .title
       , .row [ .button "-" .plain (if m.count = 0 then none else some .dec)
              , .text s!"{m.count}" .body
              , .button "+" .primary (some .inc) ]
       , .row [ .field "Add a note" m.draft .setDraft (some .addNote)
              , .button "Add" .primary (if (trimNote m.draft).isEmpty then none else some .addNote) ]
       , .col ((visible m).map noteRow)
       , .divider
       , .row [ filterButton m .all "All", filterButton m .pending "Pending" ]
       , .text s!"{m.count} clicks, {pendingCount m} of {m.notes.length} notes pending" .caption
       , .button "Clear" .destructive (if m.count = 0 ∧ m.notes.length = 0 then none else some .clear) ]

/-- The app value: what the oracle serves and what the generator reads. -/
def app : App Model Msg := ⟨Model.init, update, view⟩

end Counter
