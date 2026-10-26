import Todo.Model

namespace Todo
open ElmLean

def trimTitle (s : String) : String := s.trimAscii.copy

def setDoneIf (id : Nat) (b : Bool) (t : Todo) : Todo :=
  if t.id = id then { t with done := b } else t

def update : Msg → Model → Model
  | .setDraft s, m => { m with draft := s }
  | .add, m =>
    let title := trimTitle m.draft
    if title.isEmpty then m
    else { m with todos := ⟨m.nextId, title, false⟩ :: m.todos, draft := "", nextId := m.nextId + 1 }
  | .setDone id b, m => { m with todos := m.todos.map (setDoneIf id b) }
  | .delete id, m => { m with todos := m.todos.filter (fun t => t.id != id) }
  | .setFilter f, m => { m with filter := f }
  | .clearDone, m => { m with todos := m.todos.filter (fun t => !t.done) }

end Todo
