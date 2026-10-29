import Std.Sync.Mutex
import Std.Data.HashMap
import ElmLean.Native.Client.Auth

/-! # ElmLean.Native.EffectScope: effects that end with the state they belong to

An optional native support module. An app's slow work belongs to something that can end while it runs:
an open document, a signed-in account, a wallet, a screen. An `EffectScope` is one such thing. The app
`capture`s a `Token` when it starts work, and `invalidate`s the scope when the thing ends (another wallet
opens, the network changes, the app goes to the background): every token captured before is stale from
then on, the work spawned under them is cancelled and drained, and their late results are dropped. What
a scope stands for, and when it ends, is the app's.

## The contract

* **Tokens are opaque.** A token is `(scope, epoch)`, made only by `capture` (its constructor is private).
  Scopes get distinct identities, so a token of one scope is never valid in another.
* **Invalidation is monotonic.** `invalidate` moves the epoch forward and it never moves back: a token
  that is stale stays stale (`Model.stale_after_invalidate`, below).
* **Registration is race-free.** `spawn token work` checks the token and registers the task in one critical
  section of the scope's lock. An `invalidate` therefore either comes first (the spawn answers `.stale` and
  the work never runs) or after (the task is registered, and that invalidation cancels it and waits for it).
  No task spawned under a token escapes the invalidation that makes the token stale.
* **Invalidation drains.** `invalidate` returns once every task registered before it has returned:
  cancelled cooperatively (`IO.cancel`, which the work reads with `IO.checkCanceled`, and the task's own
  `cancel` hook for I/O the runtime cannot interrupt), then waited for. Work that ignores both keeps
  `invalidate` waiting.
* **Results are scoped.** `deliver token k` runs `k` only while the token is valid, holding the scope's
  lock, so no delivery happens after an `invalidate` has moved the epoch on. `k` should be short (post a
  message) and must not use the same scope (the lock is not reentrant).
* **Failures do not strand anything.** A task that throws is removed from the scope like one that returns;
  its error is in its task. `spawn` hands back the task, so the caller sees every result or error.

## Authentication

`authenticated token authenticate action` checks the token before asking (no prompt for stale work),
asks, and then starts `action` through `spawn`, so the check after the answer and the start of the
protected work are one step: if the scope was invalidated while the person was answering, the protected
work never starts. It answers `.done a`, `.failed e` (the protected work threw), `.denied`, `.cancelled`,
`.error` (the authentication's own failure, kept whole) or `.stale stage` with the stage the scope was
found stale at: before the prompt, after the answer, or during the protected work (which was cancelled and
drained; its result is not reported). Whether to skip authentication in a test build is the app's: it
passes its own `authenticate`.

## What it does not do

The linearization points are the scope's lock: `capture`, `isValid`, `invalidate`'s epoch step, `spawn`'s
registration, `deliver`. A validity check is true at that instant only. Work that checked its token and then
writes a file, sends a request or signs something does that I/O after the check, and an invalidation can
come in between: **a check does not make later I/O atomic with invalidation**, and **invalidation cannot
undo an external effect that has started** (a request already sent, a record already saved). Code that must
not perform an effect for a stale scope does it inside `deliver` (short, local effects) or makes the effect
itself idempotent or checkable. The authentication prompt itself is not cancelled by invalidation (the shell
has no way to withdraw it); its answer is dropped.

`Model` states the epoch rule as pure Lean and proves it; that theorem is about the model only (that a
token captured at epoch `e` is not valid at any later epoch). It says nothing about the lock, the scheduler,
`IO.cancel`, the shell's authentication or any I/O; those are tested (`ElmLeanTest/EffectScope.lean`), not
proven. -/

namespace ElmLean.Native
open Lean

/-! ### The epoch rule, as pure Lean: what the theorems below are about, and nothing more -/
namespace EffectScope.Model

/-- A token is valid exactly at the epoch it was captured at, in its own scope. -/
def valid (scope epoch : Nat) (tokenScope tokenEpoch : Nat) : Bool := tokenScope == scope && tokenEpoch == epoch

/-- Invalidating `n ≥ 1` times leaves no token of an earlier epoch valid. -/
theorem stale_after_invalidate (scope epoch tokenScope tokenEpoch n : Nat) (h : tokenEpoch ≤ epoch) (hn : 0 < n) :
    valid scope (epoch + n) tokenScope tokenEpoch = false := by
  unfold valid
  have : tokenEpoch ≠ epoch + n := by omega
  simp [this]

/-- A token of another scope is never valid. -/
theorem other_scope_never_valid (scope epoch tokenScope tokenEpoch : Nat) (h : tokenScope ≠ scope) :
    valid scope epoch tokenScope tokenEpoch = false := by
  simp [valid, h]

end EffectScope.Model

initialize scopeIdentities : IO.Ref Nat ← IO.mkRef 0

namespace EffectScope

/-- One capture of a scope. Opaque: only `capture` makes one. -/
structure Token where
  private mk ::
  scope : Nat
  epoch : Nat
  deriving BEq, Repr, Inhabited

structure Entry where
  task : Task (Except IO.Error Unit)
  cancel : IO Unit

instance : Nonempty Entry := ⟨⟨.pure (.ok ()), pure ()⟩⟩

structure State where
  epoch : Nat := 0
  tasks : Std.HashMap Nat Entry := {}
  nextTask : Nat := 0

instance : Nonempty State := ⟨{}⟩

end EffectScope

open EffectScope in
/-- A region of the app's life whose effects end together (see the module documentation). -/
structure EffectScope where
  id : Nat
  state : Std.Mutex EffectScope.State
  deriving Nonempty

namespace EffectScope

def new : BaseIO EffectScope := do
  let id ← scopeIdentities.modifyGet fun n => (n, n + 1)
  return { id, state := ← Std.Mutex.new {} }

/-- A token of the scope as it is now. -/
def capture (s : EffectScope) : BaseIO Token := do
  return ⟨s.id, ← s.state.atomically (return (← get).epoch)⟩

/-- Whether the token is of this scope and no invalidation came after it. True at this instant only. -/
def isValid (s : EffectScope) (t : Token) : BaseIO Bool := do
  if t.scope != s.id then return false
  return (← s.state.atomically (return (← get).epoch)) == t.epoch

/-- The tasks registered and not yet returned (for diagnostics and tests). -/
def liveTasks (s : EffectScope) : BaseIO Nat := s.state.atomically (return (← get).tasks.size)

/-- Ends the scope's current epoch: every token captured so far is stale, and every registered task is
cancelled and waited for before this returns. Any thread; not from inside one of the scope's tasks (it
would wait for itself). -/
def invalidate (s : EffectScope) : IO Unit := do
  let entries ← s.state.atomically (modifyGet fun st => (st.tasks.toList.map (·.2), { st with epoch := st.epoch + 1 }))
  for e in entries do
    IO.cancel e.task
    try e.cancel catch _ => pure ()
  for e in entries do
    discard <| IO.wait e.task

/-- What `spawn` did. -/
inductive Spawned (α : Type) where
  /-- The token was valid: the work runs, registered with the scope. -/
  | started (task : Task (Except IO.Error α))
  /-- The token was stale: the work never runs. -/
  | stale

/-- Runs `work` on a dedicated thread as a task of the scope, if `t` is valid: the check and the registration
are one step (see "Registration is race-free"). `cancel` is called once if an invalidation cancels the task,
for I/O `IO.cancel` cannot interrupt. -/
def spawn (s : EffectScope) (t : Token) (work : IO α) (cancel : IO Unit := pure ()) : IO (Spawned α) := do
  if t.scope != s.id then return .stale
  let result ← IO.Promise.new
  let started ← s.state.atomically do
    let st ← get
    if st.epoch != t.epoch then return none
    let n := st.nextTask
    -- started inside the lock: its own removal below needs the lock, so it finds itself registered
    let task ← IO.asTask (prio := .dedicated) do
      let r ← work.toBaseIO
      s.state.atomically (modify fun st => { st with tasks := st.tasks.erase n })
      result.resolve r
    set { st with tasks := st.tasks.insert n ⟨task, cancel⟩, nextTask := n + 1 }
    return some task
  match started with
  | none => return .stale
  | some _ => return .started (result.result?.map fun
      | some r => r
      | none => .error (IO.userError "EffectScope: the task was dropped"))

/-- Runs `k` if `t` is valid, under the scope's lock (no invalidation in between); whether it ran. `k` must
be short and must not use this scope. -/
def deliver (s : EffectScope) (t : Token) (k : IO Unit) : IO Bool := do
  if t.scope != s.id then return false
  s.state.atomically do
    if (← get).epoch != t.epoch then return false
    k
    return true

/-- Where an `authenticated` run found its scope stale. -/
inductive Stage where
  | beforePrompt | afterAnswer | duringAction
  deriving Repr, BEq, Inhabited

/-- How an `authenticated` run ended. -/
inductive Authenticated (α : Type) where
  | done (value : α)
  /-- The protected work threw. -/
  | failed (error : IO.Error)
  | denied (error : Client.Error)
  | cancelled (error : Client.Error)
  /-- The authentication itself failed otherwise (unsupported, malformed, a native failure). -/
  | error (error : Client.Error)
  | stale (stage : Stage)

/-- Asks `authenticate` and, if the person agreed and `t` is still valid, runs `action` as a task of the
scope and waits for it (see "Authentication"). Do not call it from the shell's main thread. -/
def authenticated (s : EffectScope) (t : Token) (authenticate : IO (Client.Result Unit)) (action : IO α)
    (cancel : IO Unit := pure ()) : IO (Authenticated α) := do
  unless ← s.isValid t do return .stale .beforePrompt
  match ← authenticate with
  | .error e =>
    -- an answer for stale work is not reported as the person's decision
    unless ← s.isValid t do return .stale .afterAnswer
    return match e.kind with
      | .denied => .denied e
      | .cancelled => .cancelled e
      | _ => .error e
  | .ok () =>
    match ← s.spawn t action cancel with
    | .stale => return .stale .afterAnswer
    | .started task =>
      let r ← IO.wait task
      unless ← s.isValid t do return .stale .duringAction
      return match r with
        | .ok a => .done a
        | .error e => .failed e

/-- `authenticated` with the shell's device-owner authentication (`Client.Auth`). -/
def authenticatedWithShell (s : EffectScope) (t : Token) (fx : Effects Host) (reason : String) (action : IO α)
    (cancel : IO Unit := pure ()) : IO (Authenticated α) :=
  s.authenticated t (do return (← (Client.Auth.authenticate reason).call fx).map fun _ => ()) action cancel

end EffectScope

end ElmLean.Native
