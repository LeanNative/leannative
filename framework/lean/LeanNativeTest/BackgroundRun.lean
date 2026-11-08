import LeanNative.Native.BackgroundRun
import LeanNativeShell.BackgroundTasks

/-! # BackgroundRun's lifecycle, every interleaving the module documents

Orderings come from gates (promises the test opens), never from sleeps: a test waits for the run to
reach a point, acts, then lets it go on. The only clock is in the production deadline's own test. One
watchdog thread fails the whole run if it has not finished within two minutes. The first three cases are Winnow's `BackgroundSyncTests`
(winnow-lean ce35d2a, `LeanApp/RecordsTest.lean`), carried over. -/

open LeanNative.Native Lean
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

/-- The shell's background tasks as the app meets them: `LeanNativeShell.PendingTasks` (the shell's
bookkeeping, step for step) behind `bgtask.complete`, with what iOS was told. -/
structure FakeShell where
  state : IO.Ref LeanNativeShell.PendingTasks
  /-- every `bgtask.complete` the app sent: its arguments, and whether the shell completed a task with it -/
  asked : IO.Ref (Array (Json × Bool))
  /-- what iOS heard: each task completed, by its tag, with its success (the shell's own unsuccessful
  completion of a task its successor replaced among them) -/
  ios : IO.Ref (Array (Nat × Bool))

def FakeShell.new : BaseIO FakeShell := return ⟨← IO.mkRef {}, ← IO.mkRef #[], ← IO.mkRef #[]⟩

def FakeShell.fx (sh : FakeShell) : Effects Unit :=
  { post := fun _ => pure ()
    cap := fun _ _ _ => pure ()
    ask := fun name args => do
      if name != "bgtask.complete" then return .pure (Json.mkObj [("error", "unsupported")])
      let id := (args.getObjValAs? String "id").toOption.getD ""
      let success := (args.getObjValAs? Bool "success").toOption.getD false
      let tag := (args.getObjValAs? Nat "tag").toOption
      let done ← sh.state.modifyGet fun s => let (s', t) := s.complete id tag; (t, s')
      if let some t := done then sh.ios.modify (·.push (t, success))
      sh.asked.modify (·.push (args, done.isSome))
      return .pure (if done.isSome then Json.mkObj [("ok", true)] else Json.mkObj [("ok", false), ("error", "notPending")]) }

/-- iOS launches task `id`: the shell ends the one pending under it and records the new launch; the system
event the app is to hear (`{"bgtask":{"id","kind","tag"}}`). -/
def FakeShell.launched (sh : FakeShell) (id : String) (kind := "refresh") : IO Json := do
  let (tag, ended) ← sh.state.modifyGet fun s => let (s', t, e) := s.launched id; ((t, e), s')
  if let some e := ended then sh.ios.modify (·.push (e, false))
  return LeanNativeShell.PendingTasks.event false id kind tag

/-- iOS expires the pending task `id`: its system event, if the shell posts one. -/
def FakeShell.expires (sh : FakeShell) (id : String) (kind := "refresh") : IO (Option Json) := do
  let s ← sh.state.get
  let some tag := s.pending.lookup id | return none
  return if s.expires id tag then some (LeanNativeShell.PendingTasks.event true id kind tag) else none

/-- The app hearing a system event, as an app on `BackgroundTasks` does: a launch runs `config`, an expiry
expires its run. The launched run, if any. -/
def hear (t : BackgroundTasks) (fx : Effects Unit) (event : Json) (config : BackgroundRun.Config) :
    IO (Option BackgroundRun) := do
  match BackgroundTasks.systemEvent? event with
  | some e =>
    if e.expired then
      t.expire e.id e.tag
      return none
    return some (← t.launch fx e.id config (tag := e.tag))
  | none => return none

/-- A run's config whose work waits for `release` (or its cancellation), then returns `result`. -/
def held (started release : Gate) : BackgroundRun.Config :=
  { work := do started.open; release.wait; pure true, cancel := release.open, completion := fun _ => pure () }

/-- A run's config whose work returns `result` at once. -/
def quick (result : Bool) : BackgroundRun.Config := { work := pure result, completion := fun _ => pure () }

/-- `LeanNative.Native.BackgroundTasks` against the shell's bookkeeping, through the system events the
shell posts: one answer per launch, with its tag, and none that could end a later launch of the same
identifier. -/
def tasks : IO Unit := do
  let tagged (id : String) (success : Bool) (tag : Nat) : Json :=
    Json.mkObj [("id", Json.str id), ("success", Json.bool success), ("tag", toJson tag)]
  -- a launched task that completes: removed, answered with success and its launch's tag
  let sh ← FakeShell.new
  let t ← BackgroundTasks.new
  let some r ← hear t sh.fx (← sh.launched "refresh") (quick true) | check "a launched task runs" false
  discard <| outcomeOf "task" r
  check "a launched task completes and is answered, with its tag"
    ((← sh.asked.get) == #[(tagged "refresh" true 1, true)] && (← sh.ios.get) == #[(1, true)] && (← t.find? "refresh").isNone)
  -- an expired task: its run is expired, drains, and is answered unsuccessfully
  let started ← Gate.new
  let release ← Gate.new
  let some r ← hear t sh.fx (← sh.launched "processing" "processing") (held started release) | check "a launched task runs" false
  discard <| within "started" started.p.result?
  let some ev ← sh.expires "processing" "processing" | check "the shell posts the expiry" false
  discard <| hear t sh.fx ev (quick true)
  let o ← outcomeOf "expired task" r
  check "an expired task drains and is answered unsuccessfully" (o.ended == .expired &&
    (← sh.asked.get).back? == some (tagged "processing" false 2, true) && (← sh.ios.get) == #[(1, true), (2, false)])
  -- a late expiry answers nothing: the run completed on its own and answered; iOS's expiry, which the shell
  -- posted before that answer reached it, arrives after iOS has launched the task again. Answering it would
  -- end the new task before its run started.
  let sh ← FakeShell.new
  let t ← BackgroundTasks.new
  let some r ← hear t sh.fx (← sh.launched "refresh") (quick true) | check "a launched task runs" false
  let some lateExpiry ← sh.expires "refresh" | check "the shell posts the expiry" false
  discard <| outcomeOf "completed before its expiry" r
  let relaunch ← sh.launched "refresh"
  discard <| hear t sh.fx lateExpiry (quick true)
  t.expire "never.launched"
  check "a late expiry answers nothing, nor one without a run" ((← sh.asked.get).size == 1)
  let some r ← hear t sh.fx relaunch (quick false) | check "the new launch runs" false
  discard <| outcomeOf "the new launch" r
  check "a late expiry: the new launch is answered by its own run" ((← sh.ios.get) == #[(1, true), (2, false)] &&
    (← sh.asked.get).back? == some (tagged "refresh" false 2, true))
  -- a replaced run's completion is not sent: iOS launched the task again while its run was still going (the
  -- shell has ended the old task); the old run is expired and drains, the new one answers. With tags and
  -- without (a shell before tags, where an untagged answer from the old run would end the new task).
  for withTags in [true, false] do
    let label := if withTags then "tagged" else "untagged"
    let sh ← FakeShell.new
    let t ← BackgroundTasks.new
    let strip (j : Json) : Json := if withTags then j else
      Json.mkObj [("bgtask", Json.mkObj [("id", "refresh"), ("kind", "refresh")])]
    let started ← Gate.new
    let release ← Gate.new
    let finishLater ← Gate.new
    let later := { (quick true) with work := do finishLater.wait; pure true }
    let some first ← hear t sh.fx (strip (← sh.launched "refresh")) (held started release) | check "a launched task runs" false
    discard <| within "started" started.p.result?
    let some second ← hear t sh.fx (strip (← sh.launched "refresh")) later | check "the new launch runs" false
    let o1 ← outcomeOf "the replaced run" first
    check s!"a replaced run ({label}): expired, and sends no completion" (o1.ended == .expired && (← sh.asked.get).isEmpty)
    -- an expiry naming the replaced launch leaves the new run alone
    if withTags then t.expire "refresh" (some 1)
    finishLater.open
    let o2 ← outcomeOf "the new run" second
    check s!"a replaced run ({label}): the new task is completed once, by its own run" (o2.success &&
      (← sh.ios.get) == #[(1, false), (2, true)] && (← sh.asked.get).size == 1 && (← t.find? "refresh").isNone)
  -- a stale tag: the old run finishes on its own after iOS launched the task again but before the app has
  -- heard of it, so the run is still the app's current one and answers, with the old launch's tag; the shell
  -- does not give that answer to the new task, which its own run then completes
  let sh ← FakeShell.new
  let t ← BackgroundTasks.new
  let started ← Gate.new
  let release ← Gate.new
  let some old ← hear t sh.fx (← sh.launched "refresh") (held started release) | check "a launched task runs" false
  discard <| within "started" started.p.result?
  let relaunch ← sh.launched "refresh"
  release.open
  discard <| outcomeOf "the old run" old
  check "a stale tag: the old run's answer is refused, the new task still pending"
    ((← sh.asked.get) == #[(tagged "refresh" true 1, false)] && (← sh.ios.get) == #[(1, false)] &&
      (← sh.state.get).pending == [("refresh", 2)])
  let some new ← hear t sh.fx relaunch (quick false) | check "the new launch runs" false
  discard <| outcomeOf "the new run" new
  check "a stale tag: the new task is completed by its own run" ((← sh.ios.get) == #[(1, false), (2, false)] &&
    (← sh.asked.get).back? == some (tagged "refresh" false 2, true))
  -- an answer without a tag (an app before tags): still completes the task pending under its identifier
  let sh ← FakeShell.new
  discard <| sh.launched "refresh"
  discard <| sh.fx.ask "bgtask.complete" (Json.mkObj [("id", "refresh"), ("success", true)])
  check "an untagged answer completes the pending task" ((← sh.ios.get) == #[(1, true)] && (← sh.asked.get).map (·.2) == #[true])
  let t ← BackgroundTasks.new
  let untagged := Json.mkObj [("bgtask", Json.mkObj [("id", "refresh"), ("kind", "refresh")])]
  discard <| sh.launched "refresh"
  let some r ← hear t sh.fx untagged (quick true) | check "an untagged launch runs" false
  discard <| outcomeOf "untagged" r
  check "a launch without a tag is answered without one, and completes its task"
    ((← sh.asked.get).back? == some (Json.mkObj [("id", "refresh"), ("success", true)], true) && (← sh.ios.get) == #[(1, true), (2, true)])
  -- the system events, with and without a tag
  let ev (k : String) := Json.mkObj [(k, Json.mkObj [("id", "x"), ("kind", "processing"), ("tag", (7 : Nat))])]
  check "system events" (BackgroundTasks.systemEvent? (ev "bgtask") == some { expired := false, id := "x", kind := "processing", tag := some 7 } &&
    BackgroundTasks.systemEvent? (ev "bgtaskExpired") == some { expired := true, id := "x", kind := "processing", tag := some 7 } &&
    BackgroundTasks.systemEvent? untagged == some { expired := false, id := "refresh", kind := "refresh" } &&
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
