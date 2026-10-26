import ElmLean.Erase

namespace ElmLean

/-- An Elm program: no effects, no subscriptions. -/
structure App (Model Msg : Type) where
  init : Model
  update : Msg → Model → Model
  view : Model → Html Msg

/-- Server-side session state. `lastView` is the tree the client is looking at;
events are dispatched against it, never against a freshly rendered tree. -/
structure Session (Model Msg : Type) where
  seq : Nat
  model : Model
  lastView : Html Msg

inductive ErrorCode where
  | stale
  | badPath
  | noHandler
  | badJson (detail : String)
  deriving Repr, DecidableEq

structure Request where
  seq : Nat
  path : List Nat
  event : Event
  deriving Repr, DecidableEq

inductive Reply where
  | view (seq : Nat) (w : Wire)
  | error (seq : Nat) (code : ErrorCode) (current : Option Wire)
  deriving Repr

variable {Model Msg : Type}

def Session.start (app : App Model Msg) : Session Model Msg :=
  ⟨0, app.init, app.view app.init⟩

/-- The whole protocol step as a pure, total function. The trusted shell only
parses a line into a `Request`, calls this, and prints the `Reply`. -/
def Session.handle (app : App Model Msg) (s : Session Model Msg) (r : Request) :
    Session Model Msg × Reply :=
  if r.seq ≠ s.seq then (s, .error s.seq .stale (some s.lastView.toWire))
  else match s.lastView.at? r.path with
    | none => (s, .error s.seq .badPath none)
    | some node =>
      match node.handle r.event with
      | none => (s, .error s.seq .noHandler none)
      | some msg =>
        let m' := app.update msg s.model
        let v' := app.view m'
        ({ seq := s.seq + 1, model := m', lastView := v' }, .view (s.seq + 1) v'.toWire)

/-- Fold a whole request trace. -/
def Session.run (app : App Model Msg) : Session Model Msg → List Request → Session Model Msg
  | s, [] => s
  | s, r :: rs => run app (s.handle app r).1 rs

/-- Test-only: back to the initial model, advancing `seq`. -/
def Session.reset (app : App Model Msg) (s : Session Model Msg) : Session Model Msg :=
  { seq := s.seq + 1, model := app.init, lastView := app.view app.init }

end ElmLean
