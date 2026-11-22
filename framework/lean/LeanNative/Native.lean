import Lean.Data.Json
import Std.Sync.Mutex
import Std.Data.HashMap
import LeanNative.CmdCli
import LeanNative.Record
import LeanNative.Tag

/-! # TRUSTED SHELL: native mode (the app compiled to C, inside the iOS app)

In native mode an app is ordinary Lean, compiled by Lean's compiler to C and linked into the iOS app
with Lean's runtime. The generic LeanNative shell (an Objective-C/UIKit renderer of the `Wire` tree,
printed by `lake exe leannative-shell`; a C shim, framework/native/c; and a capability host for what only iOS can
do) drives it through five C entry points
exported here, all speaking JSON:

| C function (framework/native/c) | Lean | does |
|---|---|---|
| `leannative_start()` | `start` | the initial view; runs the app's `boot` commands |
| `leannative_event(json)` | `event` | one user event `{"seq","path","event"}`, answered exactly like `Session.step` |
| `leannative_drain()` | `drain` | applies every host answer queued since the last call (`update (app.host h)` each) |
| `leannative_cap_result(json)` | `capResult` | the shell's answer `{"id","result"}` to a capability request |
| `leannative_wait()` | `wait` | blocks a shell thread until something is queued (then the shell drains on its main thread) |

Every reply is `{"seq","view","caps":[{"id","name","args"}]}` (or an error reply of PROTOCOL.md). The
app's commands are run by its own Lean `perform`, which may start tasks (network, timers, files) and
answer later with `post` from any thread, or ask the shell for a capability with `cap`; the answer
returns through the continuation given to `cap`, as a host message. So user events and host answers
reach `update` exactly as in `Session.step`, and the theorems about `CmdApp` apply unchanged. -/

namespace LeanNative.Native
open Lean

/-- What a command's runner may do. -/
structure Effects (Host : Type) where
  /-- Queue a host answer (any thread); the shell applies it on its next `drain`. -/
  post : Host → IO Unit
  /-- Ask the shell for an iOS capability (`name`, `args`); its result comes back as `k result`. -/
  cap : (name : String) → (args : Json) → (k : Json → Host) → IO Unit
  /-- Ask the shell for a capability and get its result as a task (for Lean code that needs the answer
  itself, e.g. a path before opening a file). Do not wait on it from the shell's main thread. -/
  ask : (name : String) → (args : Json) → IO (Task Json)

/-- How the runtime names the messages and commands an app handles, for the record a run keeps
(`LEANNATIVE_COVERAGE`): nothing by default, and `Tagging.derived` with the app's `LeanNative.Tag` instances, which
are derived where the record is wanted (a journeys executable), not in the app that ships. -/
structure Tagging (Msg Cmd : Type) where
  msg : Option (Msg → String) := none
  cmd : Option (Cmd → String) := none
  allMsgs : Array String := #[]
  allCmds : Array String := #[]

def Tagging.derived [Tag Msg] [Tag Cmd] : Tagging Msg Cmd :=
  { msg := some Tag.tag, cmd := some Tag.tag, allMsgs := Tag.all (α := Msg), allCmds := Tag.all (α := Cmd) }

/-- An app in native mode: a `CmdApp` plus the Lean code that runs its commands. -/
structure App (Model Msg Cmd Host : Type) extends CmdApp Model Msg Cmd Host where
  /-- Run one command. Called on the shell's main thread: start a task for anything slow. A task that runs
  for the app's life (a timer, a sync loop) takes `IO.asTask (prio := .dedicated)`, a thread of its own: at
  the default priority it holds a worker of Lean's shared task pool for good, and in Lean 4.35 a task queued
  just after it can then wait for ever (native-demo's ticker did that to the headless journeys' socket).

  An exception it throws is that command's alone: the runtime writes it to stderr (the error, never the
  command, which may hold a secret) and goes on, so the commands after it still run and the host answers
  queued behind it are still applied. The model has already taken the message; an app that must hear of a
  failure catches it in `perform` and posts a host answer. -/
  perform : Cmd → Effects Host → IO Unit
  /-- Commands run once, at start. -/
  boot : List Cmd := []
  /-- What the shell's system events mean to the app (`{"scene":"active"|"inactive"|"background"}`,
  `{"captured":bool}` while the screen is recorded or mirrored, `{"bgtask":{"id","kind","tag"}}` when iOS
  launches a background task and `{"bgtaskExpired":{"id","kind","tag"}}` when it expires one): a host message,
  or nothing. -/
  system : Json → Option Host := fun _ => none
  /-- How the record a run keeps names its messages and commands (`Tagging`); none: they are not named. -/
  tagging : Tagging Msg Cmd := {}

structure CapRequest where
  id : Nat
  name : String
  args : Json

structure Shared (Host : Type) where
  inbox : Array Host := #[]
  caps : Array CapRequest := #[]
  /-- What to do with each pending capability's result (run on the shell's thread, outside the lock). -/
  waiting : Std.HashMap Nat (Json → IO Unit) := {}
  nextCap : Nat := 0

instance : Nonempty (Shared Host) := ⟨{}⟩

/-- The type-erased running app the exported functions call. -/
structure Runtime where
  start : IO String
  event : String → IO String
  system : String → IO String
  drain : IO String
  capResult : String → IO Unit
  wait : IO Unit
  /-- The session's `seq` and the view the shell is looking at (`lastView`), for a headless driver
  (`LeanNative.Journey.Wire`) that finds elements in the tree instead of on a screen. -/
  current : IO (Nat × Wire)

instance : Nonempty Runtime := ⟨⟨pure "", fun _ => pure "", fun _ => pure "", pure "", fun _ => pure (), pure (), pure (0, .divider)⟩⟩

initialize registry : IO.Ref (Option Runtime) ← IO.mkRef none

variable {Model Msg Cmd Host : Type}

/-- The record a run keeps when `LEANNATIVE_COVERAGE` names a file (a journey's headless app is given one):
every message `update` took and command `perform` was given, by tag (`App.tagging`), every capability asked of the
shell and whether its answer was a failure, and every element identifier a view showed (`LeanNative.Tally`). The
file is written whole, then renamed into place, after each step that changed the record, so a process killed
between steps (a journey ends its app with a kill) leaves everything it did. Nothing is kept without the
variable. -/
structure Recorder where
  path : System.FilePath
  tally : IO.Ref Tally
  dirty : IO.Ref Bool
  /-- each pending capability's name, for its answer -/
  asked : IO.Ref (Std.HashMap Nat String)

def Recorder.start? (tagging : Tagging Msg Cmd) (to : Option System.FilePath := none) : IO (Option Recorder) := do
  let some path ← (match to with | some p => pure (some p.toString) | none => IO.getEnv "LEANNATIVE_COVERAGE")
    | return none
  if path.isEmpty then return none
  return some { path, tally := ← IO.mkRef { allMsgs := tagging.allMsgs, allCmds := tagging.allCmds },
                dirty := ← IO.mkRef true, asked := ← IO.mkRef {} }

def Recorder.note (r : Recorder) (f : Tally → Tally) : IO Unit := do
  r.tally.modify f
  r.dirty.set true

/-- The record to its file, if it changed: written beside it, then renamed over it. -/
def Recorder.flush (r : Recorder) : IO Unit := do
  unless ← r.dirty.get do return
  r.dirty.set false
  let tmp := r.path.toString ++ ".tmp"
  try
    IO.FS.writeFile tmp ((← r.tally.get).toJson.compress ++ "\n")
    IO.FS.rename tmp r.path
  catch e => IO.eprintln s!"LeanNative: the record could not be written: {e}"

def capJson (c : CapRequest) : Json :=
  Json.mkObj [("id", toJson c.id), ("name", Json.str c.name), ("args", c.args)]

/-- Build the running app. `session` is touched only by the shell's main thread; `shared` by everyone. `record`:
where to keep the record of the run (`Recorder`), else `LEANNATIVE_COVERAGE`, else nowhere. -/
def runtime [ToJson Cmd] (app : App Model Msg Cmd Host) (record : Option System.FilePath := none) : IO Runtime := do
  let session ← IO.mkRef (Session.start app.toApp)
  let recorder ← Recorder.start? app.tagging record
  let shared ← Std.Mutex.new ({} : Shared Host)
  let cv ← Std.Condvar.new
  let post (h : Host) : IO Unit := do
    shared.atomically (modify fun s => { s with inbox := s.inbox.push h })
    cv.notifyAll
  let request (name : String) (args : Json) (k : Json → IO Unit) : IO Unit := do
    let id ← shared.atomically (modifyGet fun s =>
      (s.nextCap, { s with caps := s.caps.push ⟨s.nextCap, name, args⟩, waiting := s.waiting.insert s.nextCap k,
                           nextCap := s.nextCap + 1 }))
    if let some r := recorder then r.asked.modify (·.insert id name)
    cv.notifyAll
  let effects : Effects Host :=
    { post
      cap := fun name args k => request name args (fun j => post (k j))
      ask := fun name args => do
        let p ← IO.Promise.new
        request name args (fun j => p.resolve j)
        pure p.result! }
  -- a command's failure is its own: it is reported, the step's other commands run, the reply is still the view,
  -- and the answers queued behind it are still applied (an exception here used to end the whole drain)
  let runCmds (cs : List Cmd) : IO Unit := cs.forM fun c => do
    if let (some r, some tag) := (recorder, app.tagging.cmd) then
      r.note fun t => { t with cmds := Tally.bump t.cmds (tag c) }
    try app.perform c effects
    catch e => try IO.eprintln s!"LeanNative: a command's perform threw: {e}" catch _ => pure ()
  -- the shell receives the capability requests queued so far with every reply
  let takeCaps : IO (Array CapRequest) :=
    shared.atomically (modifyGet fun s => (s.caps, { s with caps := #[] }))
  let reply (r : Reply) : IO String := do
    let caps ← takeCaps
    let base := match r with
      | .view seq w => Json.mkObj [("seq", toJson seq), ("view", w.toJson)]
      | other => other.toJson
    if let some rec := recorder then
      if let .view _ w := r then
        rec.note fun t => { t with ids := w.identifiers.foldl (init := t.ids) fun m id => Tally.bump m id }
      rec.flush
    pure (base.setObjVal! "caps" (Json.arr (caps.map capJson))).compress
  let step (i : Input Host) : IO Reply := do
    let s ← session.get
    let (s', r, cs) := s.step app.toCmdApp i
    session.set s'
    -- the message `update` took: a user event's, as `Session.step` finds it, or a host answer's
    if let (some rec, some tag) := (recorder, app.tagging.msg) then
      let msg? := match i with
        | .event req => s.accept req
        | .host h => some (app.host h)
      if let some msg := msg? then rec.note fun t => { t with msgs := Tally.bump t.msgs (tag msg) }
    runCmds cs
    pure r
  pure
    { start := do
        runCmds app.boot
        let s ← session.get
        reply (.view s.seq s.lastView.toWire)
      event := fun line => do
        match Json.parse line >>= Request.ofJson? with
        | .error e => reply (.error (← session.get).seq (.badJson e) none)
        | .ok req => reply (← step (.event req))
      system := fun line => do
        match (Json.parse line).toOption.bind app.system with
        | some h => reply (← step (.host h))
        | none => let s ← session.get; reply (.view s.seq s.lastView.toWire)
      drain := do
        let hs ← shared.atomically (modifyGet fun s => (s.inbox, { s with inbox := #[] }))
        for h in hs do discard <| step (.host h)
        let s ← session.get
        reply (.view s.seq s.lastView.toWire)
      capResult := fun line => do
        let j := (Json.parse line).toOption.getD Json.null
        let id := (j.getObjValAs? Nat "id").toOption.getD 0
        let result := (j.getObjVal? "result").toOption.getD Json.null
        let k? ← shared.atomically (modifyGet fun s => (s.waiting[id]?, { s with waiting := s.waiting.erase id }))
        if let some rec := recorder then
          let name? ← rec.asked.modifyGet fun m => (m[id]?, m.erase id)
          if let some name := name? then
            rec.note fun t => { t with caps := Tally.bump t.caps name,
                                       capFailures := if capFailed result then Tally.bump t.capFailures name else t.capFailures }
            rec.flush
        if let some k := k? then k result
      wait := shared.atomicallyOnce cv (do let s ← get; pure (!s.inbox.isEmpty || !s.caps.isEmpty)) (pure ())
      current := do let s ← session.get; pure (s.seq, s.lastView.toWire) }

/-- Register the app this binary runs. Call it from an `initialize` block in the app's root module. -/
def register [ToJson Cmd] (app : App Model Msg Cmd Host) : IO Unit := do
  registry.set (some (← runtime app))

def withRuntime (k : Runtime → IO String) : IO String := do
  match ← registry.get with
  | some r => k r
  | none => pure "{\"error\":\"no-app\",\"detail\":\"no LeanNative native app was registered\"}"

@[export leannative_lean_start] def exportStart (_ : Unit) : IO String := withRuntime (·.start)
@[export leannative_lean_event] def exportEvent (line : String) : IO String := withRuntime (·.event line)
@[export leannative_lean_system] def exportSystem (line : String) : IO String := withRuntime (·.system line)
@[export leannative_lean_drain] def exportDrain (_ : Unit) : IO String := withRuntime (·.drain)
@[export leannative_lean_cap_result] def exportCapResult (line : String) : IO Unit := do
  if let some r ← registry.get then r.capResult line
@[export leannative_lean_wait] def exportWait (_ : Unit) : IO Unit := do
  if let some r ← registry.get then r.wait

end LeanNative.Native
