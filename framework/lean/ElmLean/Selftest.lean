import ElmLean.Json

/-! # The generic self-test (trusted shell, defense in depth)

`explore app` walks the app breadth-first from its initial model, firing every control the wire
advertises (with every event kind, and each of a few sample strings for fields), and re-checks at
runtime, after every step, what the theorems state: the reply is a view at `seq + 1`, the session
stays coherent, the wire advertises a `(path, event)` pair iff dispatching it yields a message, a
stale request is rejected with the current view and leaves the session alone, the reply's JSON
re-parses to the same text, and the app's own runtime invariant check (`Options.check`) holds.
Every app gets this for free through `elmlean-app selftest` (see `ElmLean.Cli.main`). -/

namespace ElmLean
open Lean

/-- Every path in a wire tree, the root `[]` included. -/
partial def Wire.paths (w : Wire) : List (List Nat) :=
  [] :: (w.children.mapIdx fun i c => c.paths.map (i :: ·)).flatten

namespace Selftest

variable {M Msg : Type}

structure Options (M : Type) where
  /-- Runtime mirror of the app's invariant (`Spec.Inv`), checked in every explored model. -/
  check : M → Bool := fun _ => true
  /-- Strings typed into every advertised field while exploring. -/
  inputs : List String := ["x", "  two words ", ""]
  /-- Upper bound on the number of explored steps. -/
  maxSteps : Nat := 2000

def probeEvents (inputs : List String) : List Event :=
  [.click, .submit, .toggle true, .toggle false, .select 0, .select 1, .dismiss] ++ inputs.map .input

def sameWire (a b : Wire) : Bool := a.toJson.compress == b.toJson.compress

/-- The reply's JSON re-parses and re-compresses to the same string. -/
def roundTrip (what : String) (reply : Reply) : Except String Unit := do
  let str := reply.toJson.compress
  match Json.parse str with
  | .error err => throw s!"{what}: reply JSON does not re-parse: {err}"
  | .ok j => unless j.compress == str do throw s!"{what}: reply JSON round trip differs"

/-- The checks run on every session the exploration reaches. -/
def checkSession (app : App M Msg) (opts : Options M) (what : String) (s : Session M Msg) :
    Except String Unit := do
  unless opts.check s.model do throw s!"{what}: the app's invariant check failed"
  let w := s.lastView.toWire
  unless sameWire w (app.view s.model).toWire do throw s!"{what}: lastView is not the view of the model"
  for p in w.paths do
    for e in probeEvents opts.inputs do
      unless w.advertises p e == (s.lastView.dispatch p e).isSome do
        throw s!"{what}: advertises and dispatch disagree at path {p}, event {repr e}"
  let (s', reply) := s.handle app ⟨s.seq + 1, [], .click⟩
  unless s'.seq == s.seq do throw s!"{what}: a stale request changed seq"
  match reply with
  | .error seq .stale (some cur) =>
    unless seq == s.seq && sameWire cur w do throw s!"{what}: stale reply carries the wrong seq or view"
  | _ => throw s!"{what}: a request with seq + 1 was not rejected as stale with the current view"
  roundTrip what reply

/-- Breadth-first exploration of the advertised controls. Returns `(steps, depth)`. -/
def explore (app : App M Msg) (opts : Options M := {}) : Except String (Nat × Nat) := do
  let s0 := Session.start app
  checkSession app opts "start" s0
  let mut frontier : List (Session M Msg) := [s0]
  let mut steps := 0
  let mut depth := 0
  while steps < opts.maxSteps && !frontier.isEmpty do
    let mut next : Array (Session M Msg) := #[]
    for s in frontier do
      let w := s.lastView.toWire
      for p in w.paths do
        for e in probeEvents opts.inputs do
          if steps < opts.maxSteps && w.advertises p e then
            let what := s!"step {steps + 1} (depth {depth + 1}, path {p}, event {repr e})"
            let (s', reply) := s.handle app ⟨s.seq, p, e⟩
            match reply with
            | .view seq w' =>
              unless seq == s.seq + 1 && s'.seq == seq do throw s!"{what}: seq did not advance by one"
              unless sameWire w' s'.lastView.toWire do throw s!"{what}: the reply's view is not lastView"
              roundTrip what reply
            | .error _ code _ => throw s!"{what}: an advertised control was rejected with '{code.str}'"
            checkSession app opts what s'
            next := next.push s'
            steps := steps + 1
    frontier := next.toList
    depth := depth + 1
  pure (steps, depth)

end Selftest
end ElmLean
