import Lean.Data.Json
import Std.Async

/-! # Journeys: an app's UI tests as Lean programs on the host

A journey is a Lean program that runs on the Mac, beside the simulator. It drives the app through the test
kit's driver (framework/native/testkit/LNDriver.m, one XCUITest that is the same for every app), and checks
what it sees against anything on the host: the app's own Lean code, a node, a file. Each UI step is one
command to the driver and one answer, so a step that cannot be done (an element that never appears, a
control that stays disabled) fails the journey with the driver's reason.

    def counts : Journey := ⟨"counts", do
      launch
      tap "inc"; tap "inc"
      waitUntil 5 "the count reaches 2" do return (← text "count") == "Count: 2"⟩

    def main := Journey.main [counts]

framework/native/ci/ui-tests runs an app's journeys when it is given `UI_JOURNEY`, the executable: it starts it
with the evidence directory, the executable listens on 127.0.0.1 and writes its port to `<dir>/driver-port`,
and `xcodebuild test` runs the driver alone, which connects to it. Each journey's result goes to
`<dir>/journeys.json` and the log; a failed journey is also an XCTest failure in the result bundle, with the
journey's message. Screenshots go to `<dir>/screenshots/<name>.png` and into the result bundle.

Not under Mac Catalyst: its test runner is sandboxed, and whether it may connect to the host is untested. -/

namespace LeanNative.Journey
open Lean Std.Async

/-- An element on screen, as the driver finds it. A string is an accessibility identifier (`Html.identified`). -/
inductive Find where
  /-- the element with this identifier, of any type -/
  | id (identifier : String)
  /-- a tab bar button with this title (the sidebar's item under Mac Catalyst) -/
  | tab (title : String)
  /-- the shown alert's button with this label -/
  | alert (button : String)
  /-- a button with this label -/
  | button (label : String)
  /-- a navigation bar with this title -/
  | nav (title : String)
  /-- the navigation bar's first button: back -/
  | back
  /-- an element whose label (zero-width spaces removed) matches this regular expression (NSRegularExpression) -/
  | text (pattern : String)
  /-- `child` (an `id` or a `button`) inside the element with this identifier: a stepper's `.button "Decrement"` -/
  | inside (parent : String) (child : Find)
  deriving Repr, BEq, Inhabited

instance : Coe String Find := ⟨.id⟩

def Find.toJson : Find → Json
  | .id i => Json.mkObj [("id", Json.str i)]
  | .tab t => Json.mkObj [("tab", Json.str t)]
  | .alert b => Json.mkObj [("alert", Json.str b)]
  | .button l => Json.mkObj [("button", Json.str l)]
  | .nav t => Json.mkObj [("nav", Json.str t)]
  | .back => Json.mkObj [("back", Json.bool true)]
  | .text p => Json.mkObj [("text", Json.str p)]
  | .inside parent child => (child.toJson.setObjVal! "in" (Json.str parent))

/-- How a failure names the element. -/
def Find.describe : Find → String
  | .id i => i
  | .tab t => s!"the {t} tab"
  | .alert b => s!"the alert's {b}"
  | .button l => s!"the button {l}"
  | .nav t => s!"the {t} navigation bar"
  | .back => "the back button"
  | .text p => s!"a text matching {p}"
  | .inside parent child => s!"{child.describe} in {parent}"

/-- The connection to the driver. -/
structure Driver where
  socket : TCP.Socket.Client
  /-- bytes received past the last answer read -/
  pending : IO.Ref ByteArray
  /-- where `shot` writes its PNGs (the driver also attaches them to the test) -/
  screenshots : Option String
  /-- the screenshots the running journey has taken, for journeys.json -/
  taken : IO.Ref (Array String)

/-- What a journey runs in: IO, with the driver. -/
abbrev UI := ReaderT Driver IO

/-- A line of the journey's output, flushed: ui-tests shows it in the CI log as it happens. -/
def say (line : String) : IO Unit := do
  let out ← IO.getStdout
  out.putStrLn line
  out.flush

/-- Fails the journey with this message. -/
def failure (message : String) : IO α := throw (IO.userError message)

private def newline? (b : ByteArray) : Option Nat := Id.run do
  for i in [0:b.size] do
    if b.get! i == 10 then return some i
  return none

private partial def readLine (d : Driver) : IO String := do
  let buf ← d.pending.get
  match newline? buf with
  | some i =>
    d.pending.set (buf.extract (i + 1) buf.size)
    match String.fromUTF8? (buf.extract 0 i) with
    | some s => return s
    | none => failure "the driver answered with bytes that are not UTF-8"
  | none =>
    match ← (d.socket.recv? 65536).block with
    | some more => d.pending.set (buf ++ more); readLine d
    | none => failure "the driver closed the connection (the UI test ended: see xcodebuild.log)"

/-- One command to the driver and its answer; a refusal (`ok: false`) fails the journey with the driver's reason. -/
def request (op : String) (fields : List (String × Json) := []) : UI Json := do
  let d ← read
  let line := (Json.mkObj (("op", Json.str op) :: fields)).compress ++ "\n"
  (d.socket.send line.toUTF8).block
  let answer ← readLine d
  let .ok j := Json.parse answer | failure s!"the driver's answer is not JSON: {answer}"
  if j.getObjValAs? Bool "ok" matches .ok true then return j
  failure ((j.getObjValAs? String "error").toOption.getD s!"{op} refused: {answer}")

private def seconds (s : Float) : Json := toJson s

/-- A boolean of the driver's answer; any other value fails the journey (never read as false). -/
private def bool (j : Json) (key : String) : IO Bool :=
  match j.getObjValAs? Bool key with
  | .ok b => pure b
  | .error _ => failure s!"the driver's answer has no boolean {key}: {j.compress}"

/-- The app, launched again (any running instance terminated first) with this environment. -/
def launch (env : List (String × String) := []) : UI Unit :=
  discard <| request "launch" [("env", Json.mkObj (env.map fun (k, v) => (k, Json.str v)))]

def terminate : UI Unit := discard <| request "terminate"

/-- Whether the element appears within `within` seconds (0: whether it is there now). -/
def exists? (f : Find) (within : Float := 0) : UI Bool := do
  bool (← request "exists" [("find", f.toJson), ("timeout", seconds within)]) "exists"

/-- Waits for the element; the journey fails if it does not appear within `within` seconds. -/
def waitFor (f : Find) (within : Float := 20) : UI Unit := do
  unless ← exists? f within do failure s!"{f.describe} does not appear within {within} s"

/-- Whether the element is absent, or disappears within `within` seconds. -/
def gone? (f : Find) (within : Float := 0) : UI Bool := do
  bool (← request "gone" [("find", f.toJson), ("timeout", seconds within)]) "gone"

/-- The journey fails if the element is there after `within` seconds. -/
def expectGone (f : Find) (within : Float := 1) : UI Unit := do
  unless ← gone? f within do failure s!"{f.describe} is still there after {within} s"

/-- Taps (clicks, on the Mac) the element once it appears, is scrolled into view and is enabled; the journey fails
if it never is (the test kit's checks: LNTest.h). `times`: that many taps, the checks made before the first (a
stepper's steps). -/
def tap (f : Find) (times : Nat := 1) : UI Unit :=
  discard <| request "tap" ([("find", f.toJson)] ++ if times > 1 then [("times", toJson times)] else [])

/-- Replaces the text of this field (the same checks as `tap`), then closes the keyboard. -/
def type (f : Find) (text : String) : UI Unit := discard <| request "type" [("find", f.toJson), ("text", Json.str text)]

/-- The element's label (or value), without the zero-width spaces the shell puts into long words; waits up to
`within` seconds for it to appear. -/
def text (f : Find) (within : Float := 20) : UI String := do
  let j ← request "text" [("find", f.toJson), ("timeout", seconds within)]
  return (j.getObjValAs? String "text").toOption.getD ""

/-- The element now: whether it exists, is enabled and can be tapped. -/
structure State where
  present : Bool
  enabled : Bool
  hittable : Bool
  deriving Repr

def state (f : Find) : UI State := do
  let j ← request "state" [("find", f.toJson)]
  return { present := ← bool j "exists", enabled := ← bool j "enabled", hittable := ← bool j "hittable" }

/-- Scrolls until the element can be tapped; whether it can. -/
def scrollTo (f : Find) : UI Bool := do
  bool (← request "scroll" [("find", f.toJson)]) "hittable"

/-- A screenshot, attached to the test as `name` and written to the screenshots directory as `<name>.png`. -/
def shot (name : String) : UI Unit := do
  let dir := (← read).screenshots
  discard <| request "shot" ([("name", Json.str name)] ++ dir.toList.map fun d => ("directory", Json.str d))
  (← read).taken.modify (·.push name)

/-- (iOS) The Home button: the app goes to the background. -/
def home : UI Unit := discard <| request "home"

/-- The app brought back to the foreground. -/
def activate : UI Unit := discard <| request "activate"

/-- A line in the journey's log and the test's. -/
def log (message : String) : UI Unit := do
  say s!"  {message}"
  discard <| request "log" [("message", Json.str message)]

def pause (secs : Float) : UI Unit := IO.sleep (secs * 1000).toUInt32

/-- Checks `check` every `every` seconds until it holds; the journey fails, saying `what`, if it does not within
`within` seconds. -/
def waitUntil (within : Float) (what : String) (check : UI Bool) (every : Float := 0.5) : UI Unit := do
  let deadline := (← IO.monoMsNow) + (within * 1000).toUInt64.toNat
  repeat
    if ← check then return
    if (← IO.monoMsNow) ≥ deadline then
      if ← check then return
      failure s!"{what}: not within {within} s"
    pause every

def expect (ok : Bool) (message : String) : UI Unit := unless ok do failure message

def expectEq [BEq α] [ToString α] (what : String) (actual expected : α) : UI Unit :=
  unless actual == expected do failure s!"{what}: {actual}, expected {expected}"

/-- `s` as a regular expression matching itself (NSRegularExpression's metacharacters escaped). -/
def escapeRegex (s : String) : String :=
  s.foldl (fun acc c => if "\\^$.|?*+()[]{}".contains c then acc.push '\\' |>.push c else acc.push c) ""

/-- A text that begins with `prefix`. -/
def Find.beginning (pfx : String) : Find := .text ("^" ++ escapeRegex pfx)

/-- The digits of a text as a number ("1,000,000 sats" is 1000000); none when there are none. -/
def digits (s : String) : Option Nat :=
  let ds := s.toList.filter Char.isDigit
  if ds.isEmpty then none else some (ds.foldl (fun n c => n * 10 + (c.toNat - '0'.toNat)) 0)

end LeanNative.Journey

/-- A named UI journey. -/
structure LeanNative.Journey where
  name : String
  run : LeanNative.Journey.UI Unit

namespace LeanNative.Journey
open Lean Std.Async

private def accept (server : TCP.Socket.Server) (waitMs : Nat) : IO TCP.Socket.Client := do
  let deadline := (← IO.monoMsNow) + waitMs
  repeat
    if let some c ← server.tryAccept then return c
    if (← IO.monoMsNow) ≥ deadline then
      failure s!"the driver did not connect within {waitMs / 1000} s (did xcodebuild run LNDriver/testDrive?)"
    IO.sleep 200
  failure "unreachable"

/-- An app's journey executable: `main := Journey.main [j₁, j₂, …]`, run by framework/native/ci/ui-tests as
`<exe> [journey names…] <evidence dir>` (all of them when no name is given; UI_JOURNEY="<exe> <name>" runs one). It listens on 127.0.0.1, writes the
port to `<dir>/driver-port`, waits for the driver (LEANNATIVE_DRIVER_WAIT seconds, default 3600: xcodebuild
builds the tests first), runs the journeys in order (one that fails is reported to the driver as a test failure,
and the next still runs), and writes `<dir>/journeys.json` (each journey's result, time and screenshots). 1 if any failed. -/
def main (journeys : List Journey) (args : List String) : IO UInt32 := do
  let some dir := args.getLast?
    | IO.eprintln "usage: <journeys> [journey names…] <evidence directory>"; return 2
  let names := args.dropLast
  let chosen := if names.isEmpty then journeys else journeys.filter (names.contains ·.name)
  if let some unknown := names.find? (fun n => !journeys.any (·.name == n)) then
    IO.eprintln s!"no journey named {unknown}: {journeys.map (·.name)}"; return 2
  let dir : System.FilePath := dir
  IO.FS.createDirAll dir
  let shots := dir / "screenshots"
  IO.FS.createDirAll shots
  let server ← TCP.Socket.Server.mk
  server.bind (.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := 0 })
  server.listen 1
  let port := (← server.getSockName).port
  -- written whole, then renamed: ui-tests reads it as soon as it exists
  IO.FS.writeFile (dir / "driver-port.tmp") s!"{port}\n"
  IO.FS.rename (dir / "driver-port.tmp") (dir / "driver-port")
  say s!"journeys: listening on 127.0.0.1:{port}"
  let waitSecs := ((← IO.getEnv "LEANNATIVE_DRIVER_WAIT").bind String.toNat?).getD 3600
  let .ok socket ← (accept server (waitSecs * 1000)).toBaseIO
    | say s!"journeys: the driver did not connect within {waitSecs} s (did xcodebuild run LNDriver/testDrive? xcodebuild.log)"; return 1
  let d : Driver := { socket, pending := ← IO.mkRef .empty, screenshots := some shots.toString, taken := ← IO.mkRef #[] }
  let mut results : Array Json := #[]
  let mut failed := 0
  for j in chosen do
    say s!"journey {j.name}"
    d.taken.set #[]
    let start ← IO.monoMsNow
    let outcome ← (j.run.run d).toBaseIO
    let secs := (Float.ofNat ((← IO.monoMsNow) - start)) / 1000
    match outcome with
    | .ok () =>
      say s!"journey {j.name}: passed ({secs} s)"
      results := results.push (Json.mkObj [("name", Json.str j.name), ("passed", true), ("seconds", toJson secs),
                                           ("screenshots", toJson (← d.taken.get))])
    | .error e =>
      failed := failed + 1
      say s!"journey {j.name}: FAILED ({secs} s): {e}"
      results := results.push (Json.mkObj [("name", Json.str j.name), ("passed", false), ("seconds", toJson secs),
                                           ("failure", Json.str (toString e)), ("screenshots", toJson (← d.taken.get))])
      -- the failure into the result bundle, and the app stopped for the next journey; the connection may be gone
      try
        discard <| (request "fail" [("message", Json.str s!"journey {j.name}: {e}")]).run d
        discard <| (request "terminate").run d
      catch _ => pure ()
  try discard <| (request "end").run d catch _ => pure ()
  IO.FS.writeFile (dir / "journeys.json") ((Json.arr results).pretty ++ "\n")
  say s!"journeys: {chosen.length - failed} passed, {failed} failed"
  return if failed == 0 then 0 else 1

end LeanNative.Journey
