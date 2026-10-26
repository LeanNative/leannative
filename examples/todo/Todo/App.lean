import ElmLean.Program
import Todo.View

namespace Todo
open ElmLean

/-- The app value: what the CLI serves, what the theorems are about, what `elmgen` translates. -/
def app : App Model Msg := ⟨Model.init, update, view⟩

end Todo
