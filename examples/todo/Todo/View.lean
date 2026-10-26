import Todo.Update

namespace Todo
open ElmLean

def visible (m : Model) : List Todo :=
  match m.filter with
  | .all => m.todos
  | .active => m.todos.filter (fun t => !t.done)
  | .done => m.todos.filter (fun t => t.done)

def remaining (m : Model) : Nat := (m.todos.filter (fun t => !t.done)).length

def todoRow (t : Todo) : Html Msg :=
  .row [ .toggle t.title t.done (fun b => .setDone t.id b)
       , .spacer
       , .button "Delete" .destructive (some (.delete t.id)) ]

def filterButton (m : Model) (f : Filter) (label : String) : Html Msg :=
  .button label (if m.filter = f then .primary else .plain) (some (.setFilter f))

/-- Paths: [0] title · [1,0] field · [1,1] Add · [2,i,{0 toggle,1 spacer,2 Delete}]
· [3] divider · [4,{0,1,2}] filters · [5] "n left" · [6] Clear done. -/
def view (m : Model) : Html Msg :=
  .col [ .text "Todos" .title
       , .row [ .field "What needs doing?" m.draft .setDraft (some .add)
              , .button "Add" .primary (if (trimTitle m.draft).isEmpty then none else some .add) ]
       , .col ((visible m).map todoRow)
       , .divider
       , .row [ filterButton m .all "All", filterButton m .active "Active", filterButton m .done "Done" ]
       , .text s!"{remaining m} left" .caption
       , .button "Clear done" .destructive (if m.todos.any (·.done) then some .clearDone else none) ]

/-- A message is well-targeted when any id it mentions belongs to an existing todo. -/
@[simp] def WellTargeted (m : Model) : Msg → Prop
  | .setDone id _ => ∃ t ∈ m.todos, t.id = id
  | .delete id => ∃ t ∈ m.todos, t.id = id
  | .setDraft _ => True
  | .add => True
  | .setFilter _ => True
  | .clearDone => True

end Todo
