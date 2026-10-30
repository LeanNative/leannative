import Std.Sync.Mutex
import LeanNative.Native

/-! # LeanNative.Native.BackgroundRun: one background job, started, expired and completed once

An optional native support module (import it; `LeanNative` does not). A `BackgroundRun` runs one piece of
`work` that the platform may expire at any moment: iOS launches a background task and expires it when
its time is up, or the app's own `Deadline` does. It knows nothing of what the work is; the app keeps
its task identifiers, budgets and policy. `BackgroundTasks` connects runs to the shell's `bgtask.*`
capability (`{"bgtask":…}` launches, `{"bgtaskExpired":…}` expirations, `bgtask.complete`).

## The lifecycle

```
idle ──start──► registering ──worker begins──► running ──work returns──► settled ──► done
  │                 │                              │
  └─expire─► done   └─expire: the work never runs  └─expire: cancel, drain, then done
```

Every transition happens under one mutex, so `start`, `expire` and the work's end are linearized. The
linearization points are:

* **start claims the run**: only the first `start` of an idle run does anything; a later one, or one
  after `expire`, is a no-op.
* **expire before start** (`idle`): the run is over at once; the completion is delivered from `expire`
  with `ended := .expired, workStarted := false`, and the work never runs.
* **expire during registration** (claimed, worker not yet begun): the worker checks under the lock
  before it begins, sees the expiry and does not run the work (`workStarted := false`).
* **the work settles or expiry wins** (`running`): when the work returns, the worker takes the lock. If
  no expiry is recorded, the work's own result stands (`completed`, `unfinished` or `failed`) and a
  later `expire` is a no-op. If an expiry was recorded first, the run is `expired` whatever the work
  returned: a late success cannot report success.

## Completion, drain and failures

The completion is delivered **at most once**: only the transition into `done` delivers it, and only one
caller can make that transition. It is delivered exactly once if the run is started or expired. When
the work has started, the completion comes only after

1. the work has returned (or thrown),
2. the `cancel` hook has returned, when expiry won (it is called once, on its own thread, as soon as
   the expiry is recorded),
3. `cleanup` has returned (it runs once after every started work, whatever the outcome).

so nothing the run started is still running when the app hears it ended. Failures do not strand it:

* the work throwing before any expiry is `ended := .failed error`; after expiry won, the run is still
  `expired` and the error is kept in `lateError`;
* the `cancel` hook throwing is kept in `cancelError`; the run still drains and completes;
* `cleanup` throwing is kept in `cleanupError`, and the run is then not a `success`;
* the `completion` callback throwing is ignored: the run is over either way. `wait` still returns.

## Cancellation is cooperative

Expiry asks; it cannot force. The worker's task is cancelled (`IO.cancel`, which `IO.checkCanceled`
reads inside the work) and the app's `cancel` hook runs (for work blocked in I/O the run cannot see:
close its sockets, stop its network). Work that ignores both keeps running, and the completion waits
for it: a deadline bounds when the run *asks* the work to stop, not when the work stops. Arbitrary
blocking I/O cannot be terminated from Lean, so long work should check `IO.checkCanceled` between
steps and use I/O that its `cancel` hook can interrupt. On iOS, the shell completes a task itself one
second after `bgtaskExpired` (`LeanNativeShell/BackgroundTasks.lean`), so an app's work should stop within that.

These properties are stated and tested (`LeanNativeTest/BackgroundRun.lean`); they are not proven. -/

namespace LeanNative.Native
open Lean

namespace BackgroundRun

/-- How a run's work ended. -/
inductive End where
  /-- The work returned `true` before any expiry. -/
  | completed
  /-- The work returned `false` before any expiry: it ran, and says its job is not done. -/
  | unfinished
  /-- The work threw before any expiry. -/
  | failed (error : String)
  /-- Expiry won: the run was expired (by `expire` or its deadline) before the work settled. -/
  | expired
  deriving Repr, BEq, Inhabited

/-- What a run reports, once. -/
structure Outcome where
  ended : End
  /-- Whether the work began. When it did, the completion came after it returned and cleanup finished. -/
  workStarted : Bool
  /-- The work's error, when it threw after expiry won (its result did not count). -/
  lateError : Option String := none
  /-- The `cancel` hook's error, when expiry won and the hook threw. -/
  cancelError : Option String := none
  /-- `cleanup`'s error. -/
  cleanupError : Option String := none
  deriving Repr, BEq, Inhabited

/-- The run did its job: the work completed before any expiry and its cleanup succeeded. This is what
`bgtask.complete` reports as `success`. -/
def Outcome.success (o : Outcome) : Bool := o.ended == .completed && o.cleanupError.isNone

/-- What expires a run when its time is up. `start` calls `arm fire` once; the task it returns calls
`fire` when the time is up, and should stop early when cancelled (`IO.cancel`): the run cancels it when
it completes. -/
structure Deadline where
  arm : (fire : IO Unit) → BaseIO (Task (Except IO.Error Unit))

/-- Expire the run `ms` milliseconds after it starts (on a dedicated thread that wakes every 50 ms to
see whether the run has completed). -/
def Deadline.after (ms : Nat) : Deadline where
  arm fire := IO.asTask (prio := .dedicated) do
    let deadline := (← IO.monoMsNow) + ms
    repeat
      if ← IO.checkCanceled then return
      let now ← IO.monoMsNow
      if now ≥ deadline then break
      IO.sleep (min 50 (deadline - now)).toUInt32
    fire

/-- No deadline: only `expire` ends the run early. -/
def Deadline.never : Deadline where
  arm _ := pure (.pure (.ok ()))

/-- A deadline the caller fires (tests, or an app with its own clock): the second value fires it. Firing
it before the run starts, or after the run is done, does nothing. -/
def Deadline.manual : BaseIO (Deadline × IO Unit) := do
  let armed ← IO.mkRef (none : Option (IO Unit))
  return ({ arm := fun fire => do armed.set (some fire); pure (.pure (.ok ())) },
          do if let some fire ← armed.get then fire)

/-- A run's parts. Only `work` and `completion` are required. -/
structure Config where
  /-- The job; `true` when it did all of it. Runs once, on a dedicated thread, if the run starts before
  it is expired. It should check `IO.checkCanceled` between steps (see "Cancellation is cooperative"). -/
  work : IO Bool
  /-- Asked to stop the work when expiry wins while it runs (once, on its own thread): interrupt what
  `IO.cancel` cannot, e.g. close the work's connections. It may wait for the work to drain. -/
  cancel : IO Unit := pure ()
  /-- Runs once after every started work, before the completion (release what the work held). -/
  cleanup : IO Unit := pure ()
  /-- Hears how the run ended, at most once (exactly once if the run is started or expired). -/
  completion : Outcome → IO Unit
  /-- When the run expires itself. -/
  deadline : Deadline := .never
  /-- A test seam: runs on the worker thread after `start` has claimed the run and before the work may
  begin, the window in which an expiry finds the run registering. -/
  registering : IO Unit := pure ()

inductive Phase where
  | idle | registering | running | settled | done
  deriving BEq, Repr

structure State where
  phase : Phase := .idle
  expired : Bool := false
  worker : Option (Task (Except IO.Error Unit)) := none
  deadline : Option (Task (Except IO.Error Unit)) := none
  /-- The `cancel` hook's run, started when expiry won while the work ran. -/
  cancelling : Option (Task (Except IO.Error Unit)) := none

instance : Nonempty State := ⟨{}⟩

end BackgroundRun

open BackgroundRun in
/-- One background job (see the module documentation). Make it with `BackgroundRun.new`. -/
structure BackgroundRun where
  config : Config
  state : Std.Mutex State
  /-- Resolved with the outcome when the completion has been delivered. -/
  done : IO.Promise Outcome

namespace BackgroundRun

def new (config : Config) : BaseIO BackgroundRun := do
  return { config, state := ← Std.Mutex.new {}, done := ← IO.Promise.new }

/-- Delivers the outcome. Called only by whoever moved the run to `done`, so once. -/
private def deliver (r : BackgroundRun) (o : Outcome) : IO Unit := do
  try r.config.completion o catch _ => pure ()
  r.done.resolve o

private def errorOf (t : Except IO.Error α) : Option String :=
  match t with
  | .ok _ => none
  | .error e => some (toString e)

private inductive OnExpire where
  | nothing
  | deliver
  | cancel (worker : Option (Task (Except IO.Error Unit)))

/-- Expire the run: before it starts, it is over at once; while it registers, its work never runs; while
the work runs, the work is cancelled (`IO.cancel` and the `cancel` hook) and the completion follows when
it has drained. After the work has settled, or a second time, it does nothing. Any thread. -/
def expire (r : BackgroundRun) : IO Unit := do
  let action ← r.state.atomically do
    let s ← get
    if s.expired then return OnExpire.nothing
    match s.phase with
    | .idle => set { s with expired := true, phase := .done }; return .deliver
    | .registering => set { s with expired := true }; return .nothing
    | .running =>
      let hook ← IO.asTask (prio := .dedicated) r.config.cancel
      set { s with expired := true, cancelling := some hook }
      return .cancel s.worker
    | .settled | .done => return .nothing
  match action with
  | .deliver => r.deliver { ended := .expired, workStarted := false }
  | .cancel (some w) => IO.cancel w
  | .cancel none | .nothing => pure ()

/-- The worker: begins unless expired, runs the work, settles, drains, cleans up, completes. -/
private def runWorker (r : BackgroundRun) : IO Unit := do
  try r.config.registering catch _ => pure ()
  let began ← r.state.atomically (modifyGet fun s =>
    if s.expired then (false, s) else (true, { s with phase := .running }))
  let outcome ← if !began then pure { ended := .expired, workStarted := false } else do
    let result ← r.config.work.toBaseIO
    -- the work's end and an expiry meet here: whichever took the lock first decides
    let (won, cancelling) ← r.state.atomically (modifyGet fun s =>
      if s.expired then ((false, s.cancelling), s) else ((true, none), { s with phase := .settled }))
    let cancelError ← match cancelling with
      | some t => pure (errorOf (← IO.wait t))
      | none => pure none
    let cleanupError := errorOf (← r.config.cleanup.toBaseIO)
    if won then
      let ended := match result with
        | .ok true => End.completed
        | .ok false => .unfinished
        | .error e => .failed (toString e)
      pure { ended, workStarted := true, cleanupError }
    else
      pure { ended := .expired, workStarted := true, lateError := errorOf result, cancelError, cleanupError }
  let deadline ← r.state.atomically (modifyGet fun s => (s.deadline, { s with phase := .done }))
  if let some d := deadline then IO.cancel d
  r.deliver outcome

/-- Start the run: the work on a dedicated thread, and the deadline. Only the first start of a run that
has not been expired does anything. Any thread. -/
def start (r : BackgroundRun) : IO Unit := do
  let go ← r.state.atomically (modifyGet fun s =>
    if s.phase == .idle then (true, { s with phase := .registering }) else (false, s))
  unless go do return
  let worker ← IO.asTask (prio := .dedicated) r.runWorker
  let deadline ← r.config.deadline.arm r.expire
  -- keep both tasks referenced (a dropped task counts as cancelled); an expiry that found the work
  -- running before its task was stored here is passed on now
  let (cancelNow, doneAlready) ← r.state.atomically (modifyGet fun s =>
    ((s.expired && s.phase == .running, s.phase == .done), { s with worker := some worker, deadline := some deadline }))
  if cancelNow then IO.cancel worker
  if doneAlready then IO.cancel deadline

/-- The outcome, once the completion has been delivered (blocks until then; a run that is never
started or expired never completes). Do not wait from the shell's main thread. -/
def wait (r : BackgroundRun) : IO Outcome := do
  match ← IO.wait r.done.result? with
  | some o => pure o
  | none => throw (IO.userError "BackgroundRun: the run was dropped before it completed")

/-- The outcome, if the completion has been delivered. -/
def outcome? (r : BackgroundRun) : BaseIO (Option Outcome) := do
  if ← r.done.isResolved then return (← IO.wait r.done.result?) else return none

end BackgroundRun

/-! ## The shell's background tasks -/

/-- The runs of the shell's background tasks (`bgtask.*`, `LeanNativeShell/BackgroundTasks.lean`), by task
identifier: launch one per `{"bgtask":{"id","kind"}}` system event and expire it on
`{"bgtaskExpired":{"id","kind"}}`; each run answers the shell `bgtask.complete` with its outcome's
`success`. The app decides which identifiers it handles, their budgets and their work. -/
structure BackgroundTasks where
  runs : Std.Mutex (List (String × Nat × BackgroundRun))
  serial : IO.Ref Nat
  deriving Nonempty

namespace BackgroundTasks

def new : BaseIO BackgroundTasks := do
  return { runs := ← Std.Mutex.new [], serial := ← IO.mkRef 0 }

/-- Answer the shell that task `id` is over. -/
def complete (fx : Effects Host) (id : String) (success : Bool) : IO Unit :=
  discard <| fx.ask "bgtask.complete" (Json.mkObj [("id", Json.str id), ("success", Json.bool success)])

/-- A launched task: run `config` for it and start it. A run still registered under `id` is expired
first (iOS launched a successor; the shell has completed the old task). The run's completion calls
`config.completion` and then answers `bgtask.complete`. -/
def launch (t : BackgroundTasks) (fx : Effects Host) (id : String) (config : BackgroundRun.Config) :
    IO BackgroundRun := do
  let n ← t.serial.modifyGet fun n => (n, n + 1)
  let run ← BackgroundRun.new { config with completion := fun o => do
    t.runs.atomically (modify (·.filter (·.2.1 != n)))
    try config.completion o catch _ => pure ()
    complete fx id o.success }
  let old ← t.runs.atomically (modifyGet fun rs =>
    (rs.filter (·.1 == id), (id, n, run) :: rs.filter (·.1 != id)))
  for (_, _, r) in old do r.expire
  run.start
  return run

/-- An expired task: expire its run. Without one (iOS expired it before the app launched a run for it)
the task is completed unsuccessfully at once. -/
def expire (t : BackgroundTasks) (fx : Effects Host) (id : String) : IO Unit := do
  match (← t.runs.atomically get).find? (·.1 == id) with
  | some (_, _, r) => r.expire
  | none => complete fx id false

/-- The run registered under `id`, if any. -/
def find? (t : BackgroundTasks) (id : String) : IO (Option BackgroundRun) := do
  return ((← t.runs.atomically get).find? (·.1 == id)).map (·.2.2)

/-- A `{"bgtask":{"id","kind"}}` or `{"bgtaskExpired":{"id","kind"}}` system event: `(expired, id, kind)`. -/
def systemEvent? (j : Json) : Option (Bool × String × String) :=
  let task (key : String) : Option (String × String) := do
    let t ← (j.getObjVal? key).toOption
    let id ← (t.getObjValAs? String "id").toOption
    return (id, (t.getObjValAs? String "kind").toOption.getD "other")
  match task "bgtask", task "bgtaskExpired" with
  | some (id, kind), _ => some (false, id, kind)
  | _, some (id, kind) => some (true, id, kind)
  | none, none => none

end BackgroundTasks

end LeanNative.Native
