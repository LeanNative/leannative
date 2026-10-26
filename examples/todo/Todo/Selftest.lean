import ElmLean.Cli
import Todo.App

/-! The Todo app's scripted self-test, run by `todo-cli selftest` after the framework's generic
exploration (`ElmLean.Selftest.explore`). It re-checks at runtime, on a scripted trace, what the
Todo theorems state: the invariant (`Model.checkInv`), one toggle per visible todo
(`countToggles_view`), trimming, filters, stale rejection, the number rule of PROTOCOL.md, unicode. -/

namespace Todo.Selftest
open Lean ElmLean ElmLean.Cli

abbrev TodoSession := Session Model Msg

/-- The generic per-session checks plus Todo's own. -/
def checkSession (step : String) (s : TodoSession) : Except String Unit := do
  ElmLean.Selftest.checkSession app { check := Model.checkInv } step s
  unless (view s.model).countToggles == (visible s.model).length do
    throw s!"{step}: countToggles ≠ visible.length"

/-- Send `e` at `path` with the current `seq`; expect a fresh view and run the checks. -/
def step (name : String) (s : TodoSession) (path : List Nat) (e : Event) :
    Except String TodoSession := do
  let (s', reply) := s.handle app ⟨s.seq, path, e⟩
  match reply with
  | .view seq _ =>
    unless seq == s.seq + 1 && s'.seq == s.seq + 1 do throw s!"{name}: seq did not advance by one"
    ElmLean.Selftest.roundTrip name reply
    checkSession name s'
    pure s'
  | .error _ code _ => throw s!"{name}: unexpected error reply '{code.str}'"

/-- Send a request expected to be rejected with `code`; the session must not change. -/
def expectError (name : String) (s : TodoSession) (r : Request) (code : ErrorCode) :
    Except String (Option Wire) := do
  let (s', reply) := s.handle app r
  unless s'.seq == s.seq do throw s!"{name}: seq changed on a rejected request"
  match reply with
  | .view .. => throw s!"{name}: expected error '{code.str}' but got a view"
  | .error seq c cur =>
    unless c == code do throw s!"{name}: expected error '{code.str}' but got '{c.str}'"
    unless seq == s.seq do throw s!"{name}: error reply carries wrong seq"
    ElmLean.Selftest.roundTrip name reply
    pure cur

def titles (s : TodoSession) : List String := s.model.todos.map (·.title)

def expect (name : String) (cond : Bool) (what : String) : Except String Unit :=
  unless cond do throw s!"{name}: expected {what}"

/-- The scripted trace. Returns the number of protocol steps exercised. -/
def script : Except String Nat := do
  let s := Session.start app
  checkSession "start" s
  expect "start" (s.seq == 0 && s.model.todos.isEmpty) "seq 0 and no todos"
  -- 1. type a draft with surrounding whitespace
  let s ← step "input draft" s [1, 0] (.input "  Buy milk ")
  expect "input draft" (s.model.draft == "  Buy milk ") "draft to hold the raw text"
  -- 2. submit: the title is trimmed, the draft cleared
  let s ← step "submit" s [1, 0] .submit
  expect "submit" (titles s == ["Buy milk"] && s.model.draft == "") "todos [Buy milk], empty draft"
  expect "submit" (s.model.todos.all (!·.done)) "new todo not done"
  -- 3. the Add button is disabled while the draft is blank
  let _ ← expectError "add disabled" s ⟨s.seq, [1, 1], .click⟩ .noHandler
  -- 4. toggle the first (only) row
  let s ← step "toggle" s [2, 0, 0] (.toggle true)
  expect "toggle" (s.model.todos.map (·.done) == [true]) "the todo to be done"
  -- 5. filter Active: nothing visible
  let s ← step "filter active" s [4, 1] .click
  expect "filter active" (s.model.filter == .active) "filter = active"
  expect "filter active" ((visible s.model).length == 0) "no visible rows"
  expect "filter active" ((view s.model).countToggles == 0) "zero toggles"
  -- 6. filter All again
  let s ← step "filter all" s [4, 0] .click
  expect "filter all" (s.model.filter == .all && (visible s.model).length == 1) "one visible row"
  -- 7. a stale request is rejected and carries the current view for resync
  let cur ← expectError "stale" s ⟨s.seq + 7, [4, 0], .click⟩ .stale
  match cur with
  | none => throw "stale: reply does not carry the current view"
  | some w => expect "stale" (ElmLean.Selftest.sameWire w s.lastView.toWire) "the carried view to equal lastView"
  -- 8. a syntactically valid line with an unknown event kind fails to decode
  match Json.parse "{\"seq\":0,\"path\":[],\"event\":{\"k\":\"nope\"}}" with
  | .error e => throw s!"bad event: test JSON itself failed to parse: {e}"
  | .ok j =>
    match Request.ofJson? j with
    | .ok _ => throw "bad event: Request.ofJson? accepted an unknown event kind"
    | .error _ => pure ()
  match parseCommand "{not json" with
  | .ok _ => throw "bad json: parseCommand accepted malformed input"
  | .error _ => pure ()
  -- 8b. PROTOCOL.md's number rule: seq and path elements are accepted by value, not spelling
  match Json.parse "{\"seq\":3.0,\"path\":[1e0,10e-1],\"event\":{\"k\":\"click\"}}" with
  | .error e => throw s!"number rule: test JSON itself failed to parse: {e}"
  | .ok j =>
    match Request.ofJson? j with
    | .ok r => expect "number rule" (r.seq == 3 && r.path == [1, 1]) "seq 3, path [1, 1] from 3.0, [1e0, 10e-1]"
    | .error e => throw s!"number rule: 3.0 / 1e0 / 10e-1 were rejected: {e}"
  for bad in ["{\"seq\":1.5,\"path\":[],\"event\":{\"k\":\"click\"}}",
              "{\"seq\":-1,\"path\":[],\"event\":{\"k\":\"click\"}}",
              "{\"seq\":0,\"path\":[0.5],\"event\":{\"k\":\"click\"}}"] do
    match Json.parse bad with
    | .error e => throw s!"number rule: test JSON itself failed to parse: {e}"
    | .ok j =>
      match Request.ofJson? j with
      | .ok _ => throw s!"number rule: Request.ofJson? accepted {bad}"
      | .error _ => pure ()
  -- 9. a unicode title survives the round trip
  let s ← step "input unicode" s [1, 0] (.input "héllo 😀")
  let s ← step "submit unicode" s [1, 0] .submit
  expect "submit unicode" (titles s == ["héllo 😀", "Buy milk"]) "unicode todo prepended"
  -- 10. delete the first visible row (the unicode one)
  let s ← step "delete" s [2, 0, 2] .click
  expect "delete" (titles s == ["Buy milk"]) "only Buy milk left"
  -- 11. clear done removes the toggled todo
  let s ← step "clear done" s [6] .click
  expect "clear done" (s.model.todos == []) "no todos left"
  expect "final" (s.seq == 9) "seq 9 after nine successful events"
  pure 9

/-- What `todo-cli selftest` runs on top of the generic exploration. -/
def options : ElmLean.Cli.Options Model where
  check := Model.checkInv
  script := do
    let n ← script
    pure s!"{n} successful steps, 2 rejected requests, 1 number-rule decode, 5 decode failures"

end Todo.Selftest
