import ElmLean.Native.BackgroundRun

/-! # BackgroundRun's lifecycle, every interleaving the module documents

Orderings come from gates (promises the test opens), never from sleeps: a test waits for the run to
reach a point, acts, then lets it go on. The only clock is in the production deadline's own test. One
watchdog thread fails the whole run if it has not finished within two minutes. The first three cases are Winnow's `BackgroundSyncTests`
(winnow-lean ce35d2a, `LeanApp/RecordsTest.lean`), carried over. -/

open ElmLean.Native Lean
open BackgroundRun (Outcome End Deadline)

/-- A one-shot gate: `wait` blocks until `open`. -/
structure Gate where
  p : IO.Promise Unit

def Gate.new : BaseIO Gate := return ⟨← IO.Promise.new⟩
def Gate.open (g : Gate) : BaseIO Unit := g.p.resolve ()
def Gate.wait (g : Gate) : IO Unit := do discard <| IO.wait g.p.result?

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}"
  else IO.println s!"FAIL {name}"; failures.modify (· + 1)

/-- `t`'s value. A hang is caught by the process-wide watchdog (`main`), not here. -/
def within (_name : String) (t : Task α) : IO α := IO.wait t

/-- Waits for the run's outcome. -/
def outcomeOf (name : String) (r : BackgroundRun) : IO Outcome := do
  try r.wait catch e => check s!"{name}: {e}" false; pure default

/-- A run whose completions, cancel-hook calls and work starts are counted. -/
structure Probe where
  completions : IO.Ref (Array Outcome)
  cancels : IO.Ref Nat
  works : IO.Ref Nat
  cleanups : IO.Ref Nat

def Probe.new : BaseIO Probe :=
  return ⟨← IO.mkRef #[], ← IO.mkRef 0, ← IO.mkRef 0, ← IO.mkRef 0⟩

def Probe.config (p : Probe) (work : IO Bool) (cancel : IO Unit := pure ()) (cleanup : IO Unit := pure ())
    (deadline : Deadline := .never) (registering : IO Unit := pure ()) : BackgroundRun.Config :=
  { work := do p.works.modify (· + 1); work
    cancel := do p.cancels.modify (· + 1); cancel
    cleanup := do p.cleanups.modify (· + 1); cleanup
    completion := fun o => p.completions.modify (·.push o)
    deadline, registering }

def Probe.once (p : Probe) : IO (Option Outcome) := do
  let cs ← p.completions.get
  return if cs.size == 1 then cs[0]? else none

def carriedOver : IO Unit := do
  -- testCompletionOccursOnceAndCancelsDeadline: started twice, completes once; the deadline firing
  -- afterwards and a late expire change nothing
  let p ← Probe.new
  let (deadline, fire) ← Deadline.manual
  let r ← BackgroundRun.new (p.config (pure true) (deadline := deadline))
  r.start; r.start
  let o ← outcomeOf "completes once" r
  fire; r.expire
  check "completes once, successfully" (o.success && (← p.once) == some o && (← p.works.get) == 1)
  check "no cancellation after completing" ((← p.cancels.get) == 0)
  -- testExpirationDrainsWorkAndCannotReportSuccess: the work runs until the cancel hook lets it go;
  -- the completion comes after it drained, and is a failure although the work returned true
  let p ← Probe.new
  let started ← Gate.new
  let release ← Gate.new
  let drained ← IO.mkRef false
  let drainedAtCompletion ← IO.mkRef false
  let r ← BackgroundRun.new { p.config (do started.open; release.wait; drained.set true; pure true)
      (cancel := release.open) with
    completion := fun o => do drainedAtCompletion.set (← drained.get); p.completions.modify (·.push o) }
  r.start
  discard <| within "work started" started.p.result?
  r.expire; r.expire
  let o ← outcomeOf "expired run" r
  check "an expired run drains, then fails once" (o.ended == .expired && o.workStarted && !o.success &&
    (← drainedAtCompletion.get) && (← p.completions.get).size == 1)
  check "one cancellation for two expires" ((← p.cancels.get) == 1)
  -- testDeadlineCancelsHungWork: the production deadline; the work stops only when cancelled
  let p ← Probe.new
  let r ← BackgroundRun.new (p.config (deadline := .after 10) do
    while !(← IO.checkCanceled) do IO.sleep 1
    pure true)
  r.start
  let o ← outcomeOf "deadline" r
  check "the deadline cancels hung work" (o.ended == .expired && o.workStarted && (← p.once) == some o)

def ordering : IO Unit := do
  -- duplicate starts run the work once
  let p ← Probe.new
  let r ← BackgroundRun.new (p.config (pure true))
  r.start; r.start; r.start
  discard <| outcomeOf "duplicate starts" r
  r.start
  check "duplicate starts: one work, one completion" ((← p.works.get) == 1 && (← p.completions.get).size == 1)
  -- expiry before start: over at once, from expire itself; a later start does nothing
  let p ← Probe.new
  let r ← BackgroundRun.new (p.config (pure true))
  r.expire
  let at_expire ← r.outcome?
  r.start; r.expire
  check "expired before start: completed by expire, without work" (at_expire == some { ended := .expired, workStarted := false } &&
    (← p.works.get) == 0 && (← p.cleanups.get) == 0 && (← p.completions.get).size == 1)
  -- expiry during registration: claimed by start, the worker not yet begun; the work never runs
  let p ← Probe.new
  let registering ← Gate.new
  let proceed ← Gate.new
  let r ← BackgroundRun.new (p.config (pure true) (registering := do registering.open; proceed.wait))
  r.start
  discard <| within "registering" registering.p.result?
  r.expire
  proceed.open
  let o ← outcomeOf "expired while registering" r
  check "expired while registering: the work never runs" (o == { ended := .expired, workStarted := false } &&
    (← p.works.get) == 0 && (← p.cancels.get) == 0 && (← p.cleanups.get) == 0 && (← p.once) == some o)
  -- the race, work first: the work has settled (cleanup is still running) when the expiry comes
  let p ← Probe.new
  let inCleanup ← Gate.new
  let finishCleanup ← Gate.new
  let r ← BackgroundRun.new (p.config (pure true) (cleanup := do inCleanup.open; finishCleanup.wait))
  r.start
  discard <| within "cleanup" inCleanup.p.result?
  r.expire
  finishCleanup.open
  let o ← outcomeOf "settled first" r
  check "race, work first: success stands, expire is a no-op" (o.success && (← p.cancels.get) == 0 && (← p.once) == some o)
  -- the race, expiry first: the work then returns true, too late
  let p ← Probe.new
  let started ← Gate.new
  let release ← Gate.new
  let r ← BackgroundRun.new (p.config (do started.open; release.wait; pure true))
  r.start
  discard <| within "started" started.p.result?
  r.expire
  release.open
  let o ← outcomeOf "expired first" r
  check "race, expiry first: a late success is expired" (o.ended == .expired && o.workStarted && !o.success &&
    (← p.cleanups.get) == 1 && (← p.once) == some o)

def failures' : IO Unit := do
  -- the work throws before any expiry
  let p ← Probe.new
  let r ← BackgroundRun.new (p.config (throw (IO.userError "disk full")))
  r.start
  let o ← outcomeOf "work failure" r
  check "work failure: failed, cleaned up, once" (o.ended == .failed "disk full" && !o.success &&
    (← p.cleanups.get) == 1 && (← p.once) == some o)
  -- the work throws after expiry won: still expired, the error kept
  let p ← Probe.new
  let started ← Gate.new
  let release ← Gate.new
  let r ← BackgroundRun.new (p.config (do started.open; release.wait; throw (IO.userError "connection reset")))
  r.start
  discard <| within "started" started.p.result?
  r.expire
  release.open
  let o ← outcomeOf "late failure" r
  check "late work failure: expired, error kept" (o.ended == .expired && o.lateError == some "connection reset")
  -- cleanup throws: the run completes, but not as a success
  let p ← Probe.new
  let r ← BackgroundRun.new (p.config (pure true) (cleanup := throw (IO.userError "cannot close")))
  r.start
  let o ← outcomeOf "cleanup failure" r
  check "cleanup failure: completed, not a success" (o.ended == .completed && o.cleanupError == some "cannot close" &&
    !o.success && (← p.once) == some o)
  -- the cancel hook throws: the run still drains and completes
  let p ← Probe.new
  let started ← Gate.new
  let release ← Gate.new
  let r ← BackgroundRun.new (p.config (do started.open; release.wait; pure true)
    (cancel := do release.open; throw (IO.userError "no network to stop")))
  r.start
  discard <| within "started" started.p.result?
  r.expire
  let o ← outcomeOf "cancel failure" r
  check "cancel hook failure: kept, run completes" (o.ended == .expired && o.cancelError == some "no network to stop" &&
    (← p.once) == some o)
  -- the completion throws: the run is over and wait still returns
  let r ← BackgroundRun.new { work := pure true, completion := fun _ => throw (IO.userError "app bug") }
  r.start
  let o ← outcomeOf "completion throws" r
  check "a throwing completion does not strand wait" o.success

/-- Starts and expires from many threads at once: whatever interleaving the scheduler picks, exactly one
completion, and no success once the expiry has been recorded before the work could settle. -/
def contended : IO Unit := do
  let mut ok := true
  for i in [0:300] do
    let p ← Probe.new
    let go ← Gate.new
    let r ← BackgroundRun.new (p.config (pure (i % 2 == 0)))
    let callers ← (List.range 8).mapM fun k => IO.asTask (prio := .dedicated) do
      go.wait
      if k % 2 == 0 then r.start else r.expire
    go.open
    for c in callers do discard <| within "contended caller" c
    let o ← outcomeOf "contended" r
    let cs ← p.completions.get
    ok := ok && cs.size == 1 && cs[0]? == some o && (← p.works.get) ≤ 1 &&
      (o.workStarted == ((← p.works.get) == 1)) && (o.ended != .expired || !o.success)
  check "300 contended start/expire rounds: one completion each, consistent outcomes" ok

/-- The shell's side, with a fake `bgtask.complete`. -/
def tasks : IO Unit := do
  let asked ← IO.mkRef (#[] : Array (String × Json))
  let fx : Effects Unit :=
    { post := fun _ => pure ()
      cap := fun _ _ _ => pure ()
      ask := fun name args => do
        asked.modify (·.push (name, args))
        pure (.pure (Json.mkObj [("ok", true)])) }
  let completeArgs (id : String) (success : Bool) := ("bgtask.complete", Json.mkObj [("id", Json.str id), ("success", Json.bool success)])
  let t ← BackgroundTasks.new
  -- a launched task that completes: removed, answered with success
  let r ← t.launch fx "refresh" { work := pure true, completion := fun _ => pure () }
  discard <| outcomeOf "task" r
  check "a launched task completes and is answered" ((← asked.get) == #[completeArgs "refresh" true] && (← t.find? "refresh").isNone)
  -- an expired task: its run is expired, drains, and is answered unsuccessfully
  asked.set #[]
  let started ← Gate.new
  let release ← Gate.new
  let r ← t.launch fx "processing" { work := do started.open; release.wait; pure true, cancel := release.open, completion := fun _ => pure () }
  discard <| within "started" started.p.result?
  t.expire fx "processing"
  let o ← outcomeOf "expired task" r
  check "an expired task drains and is answered unsuccessfully" (o.ended == .expired && (← asked.get) == #[completeArgs "processing" false])
  -- iOS expires a task the app has not launched a run for: answered at once
  asked.set #[]
  t.expire fx "never.launched"
  check "an expiry without a run is answered at once" ((← asked.get) == #[completeArgs "never.launched" false])
  -- a successor launched under the same identifier expires the run still pending
  asked.set #[]
  let started ← Gate.new
  let release ← Gate.new
  let first ← t.launch fx "refresh" { work := do started.open; release.wait; pure true, cancel := release.open, completion := fun _ => pure () }
  discard <| within "started" started.p.result?
  let second ← t.launch fx "refresh" { work := pure true, completion := fun _ => pure () }
  let o1 ← outcomeOf "first" first
  let o2 ← outcomeOf "second" second
  check "a successor expires the pending run" (o1.ended == .expired && o2.success && (← t.find? "refresh").isNone &&
    (← asked.get).size == 2)
  -- the system events
  let ev (k : String) := Json.mkObj [(k, Json.mkObj [("id", "x"), ("kind", "processing")])]
  check "system events" (BackgroundTasks.systemEvent? (ev "bgtask") == some (false, "x", "processing") &&
    BackgroundTasks.systemEvent? (ev "bgtaskExpired") == some (true, "x", "processing") &&
    BackgroundTasks.systemEvent? (Json.mkObj [("scene", "active")]) == none)

def main : IO UInt32 := do
  -- the watchdog: a hang is a failure, never a stuck CI job
  let watchdog ← IO.asTask (prio := .dedicated) do
    let deadline := (← IO.monoMsNow) + 120_000
    while (← IO.monoMsNow) < deadline do
      if ← IO.checkCanceled then return
      IO.sleep 50
    IO.eprintln "background-run: still running after 120 s: a run did not complete (hang)"
    (IO.Process.exit 2 : IO Unit)
  carriedOver
  ordering
  failures'
  contended
  tasks
  -- the process then exits only if no run left a thread behind (Lean waits for dedicated tasks)
  IO.cancel watchdog
  let n ← failures.get
  IO.println (if n == 0 then "background-run: all passed" else s!"background-run: {n} failed")
  return if n == 0 then 0 else 1
