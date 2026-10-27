import Lean.Data.Json
import Std.Sync.Mutex
import Std.Data.HashMap
import ElmLean.CmdCli

/-! # TRUSTED SHELL: native mode (the app compiled to C, inside the iOS app)

In native mode an app is ordinary Lean, compiled by Lean's compiler to C and linked into the iOS app
with Lean's runtime. The generic ElmLean shell (an Objective-C/UIKit renderer of the `Wire` tree,
printed by `lake exe elmshell`; a C shim, framework/native/c; and a capability host for what only iOS can
do) drives it through five C entry points
exported here, all speaking JSON:

| C function (framework/native/c) | Lean | does |
|---|---|---|
| `elmlean_start()` | `start` | the initial view; runs the app's `boot` commands |
| `elmlean_event(json)` | `event` | one user event `{"seq","path","event"}`, answered exactly like `Session.step` |
| `elmlean_drain()` | `drain` | applies every host answer queued since the last call (`update (app.host h)` each) |
| `elmlean_cap_result(json)` | `capResult` | the shell's answer `{"id","result"}` to a capability request |
| `elmlean_wait()` | `wait` | blocks a shell thread until something is queued (then the shell drains on its main thread) |

Every reply is `{"seq","view","caps":[{"id","name","args"}]}` (or an error reply of PROTOCOL.md). The
app's commands are run by its own Lean `perform`, which may start tasks (network, timers, files) and
answer later with `post` from any thread, or ask the shell for a capability with `cap`; the answer
returns through the continuation given to `cap`, as a host message. So user events and host answers
reach `update` exactly as in `Session.step`, and the theorems about `CmdApp` apply unchanged. -/

namespace ElmLean.Native
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

/-- An app in native mode: a `CmdApp` plus the Lean code that runs its commands. -/
structure App (Model Msg Cmd Host : Type) extends CmdApp Model Msg Cmd Host where
  /-- Run one command. Called on the shell's main thread: start a task for anything slow. -/
  perform : Cmd → Effects Host → IO Unit
  /-- Commands run once, at start. -/
  boot : List Cmd := []
  /-- What the shell's system events mean to the app (`{"scene":"active"|"inactive"|"background"}`,
  `{"captured":bool}` while the screen is recorded or mirrored): a host message, or nothing. -/
  system : Json → Option Host := fun _ => none

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

instance : Nonempty Runtime := ⟨⟨pure "", fun _ => pure "", fun _ => pure "", pure "", fun _ => pure (), pure ()⟩⟩

initialize registry : IO.Ref (Option Runtime) ← IO.mkRef none

variable {Model Msg Cmd Host : Type}

def capJson (c : CapRequest) : Json :=
  Json.mkObj [("id", toJson c.id), ("name", Json.str c.name), ("args", c.args)]

/-- Build the running app. `session` is touched only by the shell's main thread; `shared` by everyone. -/
def runtime [ToJson Cmd] (app : App Model Msg Cmd Host) : IO Runtime := do
  let session ← IO.mkRef (Session.start app.toApp)
  let shared ← Std.Mutex.new ({} : Shared Host)
  let cv ← Std.Condvar.new
  let post (h : Host) : IO Unit := do
    shared.atomically (modify fun s => { s with inbox := s.inbox.push h })
    cv.notifyAll
  let request (name : String) (args : Json) (k : Json → IO Unit) : IO Unit := do
    shared.atomically (modify fun s =>
      { s with caps := s.caps.push ⟨s.nextCap, name, args⟩, waiting := s.waiting.insert s.nextCap k,
               nextCap := s.nextCap + 1 })
    cv.notifyAll
  let effects : Effects Host :=
    { post
      cap := fun name args k => request name args (fun j => post (k j))
      ask := fun name args => do
        let p ← IO.Promise.new
        request name args (fun j => p.resolve j)
        pure p.result! }
  let runCmds (cs : List Cmd) : IO Unit := cs.forM fun c => app.perform c effects
  -- the shell receives the capability requests queued so far with every reply
  let takeCaps : IO (Array CapRequest) :=
    shared.atomically (modifyGet fun s => (s.caps, { s with caps := #[] }))
  let reply (r : Reply) : IO String := do
    let caps ← takeCaps
    let base := match r with
      | .view seq w => Json.mkObj [("seq", toJson seq), ("view", w.toJson)]
      | other => other.toJson
    pure (base.setObjVal! "caps" (Json.arr (caps.map capJson))).compress
  let step (i : Input Host) : IO Reply := do
    let (s', r, cs) := (← session.get).step app.toCmdApp i
    session.set s'
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
        if let some k := k? then k result
      wait := shared.atomicallyOnce cv (do let s ← get; pure (!s.inbox.isEmpty || !s.caps.isEmpty)) (pure ()) }

/-- Register the app this binary runs. Call it from an `initialize` block in the app's root module. -/
def register [ToJson Cmd] (app : App Model Msg Cmd Host) : IO Unit := do
  registry.set (some (← runtime app))

def withRuntime (k : Runtime → IO String) : IO String := do
  match ← registry.get with
  | some r => k r
  | none => pure "{\"error\":\"no-app\",\"detail\":\"no ElmLean native app was registered\"}"

@[export elmlean_native_start] def exportStart (_ : Unit) : IO String := withRuntime (·.start)
@[export elmlean_native_event] def exportEvent (line : String) : IO String := withRuntime (·.event line)
@[export elmlean_native_system] def exportSystem (line : String) : IO String := withRuntime (·.system line)
@[export elmlean_native_drain] def exportDrain (_ : Unit) : IO String := withRuntime (·.drain)
@[export elmlean_native_cap_result] def exportCapResult (line : String) : IO Unit := do
  if let some r ← registry.get then r.capResult line
@[export elmlean_native_wait] def exportWait (_ : Unit) : IO Unit := do
  if let some r ← registry.get then r.wait

end ElmLean.Native
