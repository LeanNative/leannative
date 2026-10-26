import ElmLean.Html

namespace Todo
open ElmLean

structure Todo where
  id : Nat
  title : String
  done : Bool
  deriving Repr, DecidableEq, Inhabited

inductive Filter where
  | all
  | active
  | done
  deriving Repr, DecidableEq, Inhabited

structure Model where
  todos : List Todo
  draft : String
  nextId : Nat
  filter : Filter
  deriving Repr, Inhabited

inductive Msg where
  | setDraft (s : String)
  | add
  /-- Set a todo's done flag to the toggle's new value (the value is authoritative, not a flip). -/
  | setDone (id : Nat) (done : Bool)
  | delete (id : Nat)
  | setFilter (f : Filter)
  | clearDone
  deriving Repr, DecidableEq

def Model.init : Model := ⟨[], "", 0, .all⟩

/-- The model invariant: ids pairwise distinct, every id below `nextId`, no empty title. -/
def Model.Inv (m : Model) : Prop :=
  m.todos.Pairwise (fun a b => a.id ≠ b.id)
  ∧ (∀ t ∈ m.todos, t.id < m.nextId)
  ∧ (∀ t ∈ m.todos, t.title.isEmpty = false)

/-- Runtime mirror of `Model.Inv`, used by the self-test as defense in depth. -/
def Model.checkInv (m : Model) : Bool :=
  let ids := m.todos.map (·.id)
  ids.eraseDups.length == ids.length
  && m.todos.all (fun t => t.id < m.nextId)
  && m.todos.all (fun t => !t.title.isEmpty)

end Todo
