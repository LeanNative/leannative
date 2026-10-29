import ElmLean.Native.EffectScope

/-! # EffectScope: invalidation at every point the module documents

Orderings come from gates (promises the test opens), not sleeps; the registration race is also run many
times from several threads, asserting the outcome holds whichever side wins. One watchdog fails a hang, and
the binary exits only if no scoped task was left behind. -/

open ElmLean.Native Lean
open EffectScope (Token Spawned Authenticated Stage)

structure Gate where
  p : IO.Promise Unit

def Gate.new : BaseIO Gate := return ⟨← IO.Promise.new⟩
def Gate.open (g : Gate) : BaseIO Unit := g.p.resolve ()
def Gate.wait (g : Gate) : IO Unit := do discard <| IO.wait g.p.result?
def Gate.isOpen (g : Gate) : BaseIO Bool := g.p.isResolved

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}" else IO.println s!"FAIL {name}"; failures.modify (· + 1)

/-- Work that stops only when its task is cancelled. -/
def untilCancelled : IO Unit := do
  while !(← IO.checkCanceled) do IO.sleep 1

def authOk : IO (Client.Result Unit) := pure (.ok ())
def authError (kind : Client.Kind) (name : String) : IO (Client.Result Unit) :=
  pure (.error { kind, name, capability := "auth" })

def isStale : Spawned α → Bool
  | .stale => true
  | .started _ => false

def stageOf : Authenticated α → Option Stage
  | .stale st => some st
  | _ => none

def tokens : IO Unit := do
  let a ← EffectScope.new
  let b ← EffectScope.new
  let t0 ← a.capture
  check "a fresh token is valid" (← a.isValid t0)
  check "a token is never valid in another scope" (!(← b.isValid t0) && (← b.isValid (← b.capture)))
  a.invalidate
  let t1 ← a.capture
  a.invalidate; a.invalidate
  let t3 ← a.capture
  check "repeated invalidation: every earlier token stays stale" (!(← a.isValid t0) && !(← a.isValid t1) && (← a.isValid t3))
  check "tokens of different epochs differ" (t0 != t1 && t1 != t3)
  -- the model's theorem, evaluated: what it states, for these numbers
  check "the model agrees" (EffectScope.Model.valid a.id 3 t0.scope t0.epoch == false)

def spawning : IO Unit := do
  let s ← EffectScope.new
  -- invalidated before the spawn: the work never runs
  let ran ← IO.mkRef false
  let t ← s.capture
  s.invalidate
  check "invalidated before spawn: stale, never run" (isStale (← s.spawn t (ran.set true)) && !(← ran.get))
  -- a live spawn runs, reports its value, and leaves the scope
  let t ← s.capture
  match ← s.spawn t (pure 42) with
  | .started task => check "a live spawn runs and returns" ((← IO.wait task) matches .ok 42)
  | .stale => check "a live spawn runs and returns" false
  check "a finished task leaves the scope" ((← s.liveTasks) == 0)
  -- a failing task: its error is in its task, and it does not stay registered
  let failedRight ← match ← s.spawn t (throw (IO.userError "boom") : IO Nat) with
    | .started task => do
      let r ← IO.wait task
      pure (match r with | .error e => toString e == "boom" | .ok _ => false)
    | .stale => pure false
  check "a failing task reports its error and leaves the scope" (failedRight && (← s.liveTasks) == 0)
  -- invalidated during the work: cancelled, drained before invalidate returns, its result dropped
  let started ← Gate.new
  let finished ← IO.mkRef false
  let t ← s.capture
  let r ← s.spawn t (do started.open; untilCancelled; finished.set true; pure 1)
  started.wait
  s.invalidate
  check "invalidated during work: drained before invalidate returns" ((← finished.get) && (← s.liveTasks) == 0)
  let delivered ← match r with
    | .started task => do discard <| IO.wait task; s.deliver t (pure ())
    | .stale => pure true
  check "invalidated during work: its late result is not delivered" (!delivered)
  -- cancel and drain work that only its hook can stop (blocked I/O): invalidate calls the hook and waits
  let started ← Gate.new
  let release ← Gate.new
  let hooks ← IO.mkRef 0
  let t ← s.capture
  discard <| s.spawn t (do started.open; release.wait; pure ()) (cancel := do hooks.modify (· + 1); release.open)
  started.wait
  s.invalidate
  check "cancel and drain: the hook runs once, the work has returned" ((← hooks.get) == 1 && (← release.isOpen) && (← s.liveTasks) == 0)
  s.invalidate
  check "a second invalidation does not call the hook again" ((← hooks.get) == 1)

/-- Spawn racing invalidation, from several threads: whichever wins, either the spawn was refused and the
work never ran, or the work was registered and had finished when that invalidation returned. -/
def registrationRace : IO Unit := do
  let mut ok := true
  let mut refused := 0
  for _ in [0:300] do
    let s ← EffectScope.new
    let t ← s.capture
    let ran ← IO.mkRef false
    let done ← IO.mkRef false
    let go ← Gate.new
    let spawner ← IO.asTask (prio := .dedicated) do
      go.wait
      s.spawn t (do ran.set true; untilCancelled; done.set true)
    let invalidator ← IO.asTask (prio := .dedicated) do
      go.wait
      s.invalidate
      return (← done.get, ← ran.get)
    go.open
    let spawned ← IO.ofExcept (← IO.wait spawner)
    let (doneWhenInvalidated, ranBefore) ← IO.ofExcept (← IO.wait invalidator)
    let fine := match spawned with
      | .stale => !ranBefore
      | .started _ => doneWhenInvalidated
    ok := ok && fine && (← s.liveTasks) == 0
    -- a refused spawn never runs later either
    if isStale spawned then
      ok := ok && !(← ran.get)
      refused := refused + 1
  check s!"300 spawn/invalidate races ({refused} refused, {300 - refused} registered then drained): refused and never run, or registered and drained" ok

def authentication : IO Unit := do
  let s ← EffectScope.new
  -- stale before the prompt: no prompt
  let asked ← IO.mkRef 0
  let ask : IO (Client.Result Unit) := do asked.modify (· + 1); authOk
  let t ← s.capture
  s.invalidate
  check "stale before the prompt: no prompt, no action" ((stageOf (← s.authenticated t ask (pure ()))) == some .beforePrompt && (← asked.get) == 0)
  -- invalidated while the person answers: the action never starts, even though they agreed
  let ran ← IO.mkRef false
  let prompted ← Gate.new
  let answer ← Gate.new
  let t ← s.capture
  let run ← IO.asTask (prio := .dedicated) (s.authenticated t (do prompted.open; answer.wait; authOk) (ran.set true))
  prompted.wait
  s.invalidate
  answer.open
  let r ← IO.ofExcept (← IO.wait run)
  check "invalidated while awaiting authentication: stale after the answer, no action" (stageOf r == some .afterAnswer && !(← ran.get))
  -- invalidated after the answer, before the action is registered (the last thing authenticate does)
  let t ← s.capture
  check "invalidated after the answer, before the action: stale, no action"
    ((stageOf (← s.authenticated t (do s.invalidate; authOk) (ran.set true))) == some .afterAnswer && !(← ran.get))
  -- invalidated during the action: cancelled and drained, reported stale
  let started ← Gate.new
  let drained ← IO.mkRef false
  let t ← s.capture
  let run ← IO.asTask (prio := .dedicated) (s.authenticated t authOk (do started.open; untilCancelled; drained.set true))
  started.wait
  s.invalidate
  check "invalidate during the action returns after it drained" (← drained.get)
  check "invalidated during the action: stale during it" (stageOf (← IO.ofExcept (← IO.wait run)) == some .duringAction)
  -- the answers kept apart
  let t ← s.capture
  check "done" ((← s.authenticated t authOk (pure 7)) matches .done 7)
  check "denied" ((← s.authenticated t (authError .denied "authenticationFailed") (ran.set true)) matches .denied _)
  check "cancelled is not denied" ((← s.authenticated t (authError .cancelled "userCancel") (ran.set true)) matches .cancelled _)
  check "another failure is an error, kept whole" (match ← s.authenticated t (authError .unsupported "passcodeNotSet") (ran.set true) with
    | .error e => e.name == "passcodeNotSet" | _ => false)
  check "no action after a refusal" (!(← ran.get))
  check "the action's own failure" ((← s.authenticated t authOk (throw (IO.userError "disk full") : IO Unit)) matches .failed _)
  -- a refusal for work gone stale is reported as stale, not as the person's answer
  let t ← s.capture
  check "a refusal after invalidation is stale" ((stageOf (← s.authenticated t (do s.invalidate; authError .denied "authenticationFailed") (pure ()))) == some .afterAnswer)
  -- through the shell's own capability, with a fake shell
  let cancelledReply := Json.mkObj [("ok", false), ("error", "Canceled."), ("name", "userCancel"), ("code", (-2 : Int))]
  let fx : Effects Unit :=
    { post := fun _ => pure ()
      cap := fun _ _ _ => pure ()
      ask := fun _ _ => pure (.pure cancelledReply) }
  let t ← s.capture
  check "the shell's userCancel is cancelled" ((← s.authenticatedWithShell t fx "Unlock" (pure ())) matches .cancelled _)
  check "no task is left in the scope" ((← s.liveTasks) == 0)

def delivery : IO Unit := do
  let s ← EffectScope.new
  let t ← s.capture
  let got ← IO.mkRef (#[] : Array Nat)
  check "a live result is delivered" ((← s.deliver t (got.modify (·.push 1))) && (← got.get) == #[1])
  s.invalidate
  check "a late result is dropped" (!(← s.deliver t (got.modify (·.push 2))) && (← got.get) == #[1])
  let other ← EffectScope.new
  check "a token of another scope delivers nothing" (!(← other.deliver (← s.capture) (got.modify (·.push 3))) && (← got.get) == #[1])

def main : IO UInt32 := do
  let watchdog ← IO.asTask (prio := .dedicated) do
    let deadline := (← IO.monoMsNow) + 120_000
    while (← IO.monoMsNow) < deadline do
      if ← IO.checkCanceled then return
      IO.sleep 50
    IO.eprintln "effect-scope: still running after 120 s (hang)"
    (IO.Process.exit 2 : IO Unit)
  tokens
  spawning
  registrationRace
  authentication
  delivery
  IO.cancel watchdog
  let n ← failures.get
  IO.println (if n == 0 then "effect-scope: all passed" else s!"effect-scope: {n} failed")
  return if n == 0 then 0 else 1
