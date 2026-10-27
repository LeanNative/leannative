import ElmLean.Program

/-! # Commands: an app that asks its host to do things

Elm's `update : Msg → Model → (Model, Cmd Msg)` returns the commands with the new model. ElmLean
keeps `update : Msg → Model → Model` and adds a second function, `cmds : Msg → Model → List Cmd`,
the commands that the same message asks for in the same pre-state. The two are computed from the
same arguments, so nothing is lost, and both stay inside the subset `elmgen` translates (no pairs).

`Cmd` is an ordinary app type: data the host interprets (the Send example's host calls WalletCore).
The host answers with values of a second app type, `Host`, and an answer can reach `update` only as
`app.host h`. Answers are not tied to a pending command: a host may report at any time, and the app's
`update` decides what an answer means in the current model (the Send example ignores an answer about
a draft it is no longer showing). So the proofs quantify over every interleaving of user events and
arbitrary host answers.

`CmdApp` extends `App`, so every theorem about `Session.handle` applies unchanged to the user's half
of a session; `Session.step` adds the host's half. -/

namespace ElmLean

/-- An ElmLean app with commands. `toApp` is the pure part (`init`, `update`, `view`). -/
structure CmdApp (Model Msg Cmd Host : Type) extends App Model Msg where
  /-- The commands that `update msg m` asks the host to run, from the same pre-state `m`. -/
  cmds : Msg → Model → List Cmd
  /-- The only way a host answer becomes a message. -/
  host : Host → Msg

/-- What a session can receive: a user event (`seq`-guarded, path-addressed) or a host answer. -/
inductive Input (Host : Type) where
  | event (r : Request)
  | host (h : Host)

variable {Model Msg Cmd Host : Type}

/-- The message an in-sync request dispatches to, if any. -/
def Session.accept (s : Session Model Msg) (r : Request) : Option Msg :=
  if r.seq = s.seq then s.lastView.dispatch r.path r.event else none

/-- Run `update` on `msg` and show the new model's view at `seq + 1`. -/
def Session.apply (app : App Model Msg) (s : Session Model Msg) (msg : Msg) : Session Model Msg :=
  { seq := s.seq + 1, model := app.update msg s.model, lastView := app.view (app.update msg s.model) }

/-- One input: the next session, the reply, and the commands for the host. A user event is answered
exactly as `Session.handle` answers it; a host answer always runs `update (app.host h)`. -/
def Session.step (app : CmdApp Model Msg Cmd Host) (s : Session Model Msg) :
    Input Host → Session Model Msg × Reply × List Cmd
  | .event r =>
    let (s', reply) := s.handle app.toApp r
    (s', reply, match s.accept r with
      | some msg => app.cmds msg s.model
      | none => [])
  | .host h =>
    let s' := s.apply app.toApp (app.host h)
    (s', .view s'.seq s'.lastView.toWire, app.cmds (app.host h) s.model)

/-- Fold a whole input trace. -/
def Session.runC (app : CmdApp Model Msg Cmd Host) : Session Model Msg → List (Input Host) → Session Model Msg
  | s, [] => s
  | s, i :: is => runC app (s.step app i).1 is

/-- One answered input, as recorded by `Session.trace`. -/
structure Step (Model Msg Cmd Host : Type) where
  before : Session Model Msg
  input : Input Host
  cmds : List Cmd

/-- Every step of a run, in order: the session each input met, the input, the commands it produced. -/
def Session.trace (app : CmdApp Model Msg Cmd Host) :
    Session Model Msg → List (Input Host) → List (Step Model Msg Cmd Host)
  | _, [] => []
  | s, i :: is => ⟨s, i, (s.step app i).2.2⟩ :: trace app (s.step app i).1 is

/-- The trace of a run from a fresh start. -/
def CmdApp.traceFrom (app : CmdApp Model Msg Cmd Host) (is : List (Input Host)) :
    List (Step Model Msg Cmd Host) :=
  (Session.start app.toApp).trace app is

end ElmLean
