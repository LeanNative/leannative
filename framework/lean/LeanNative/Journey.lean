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

With `LEANNATIVE_DRIVER=app` the steps are carried out by the app's own driver instead
(framework/native/driver/LNAppDriver.m, in Debug builds): the host launches the app with `simctl`, passing it the
port, the app connects, and the host itself terminates it, brings it back and takes the screenshots (`simctl io`).
No XCTest runs, so a step costs milliseconds instead of XCTest's lookups and waits; what that does not test is
real touches (LNAppDriver.m says which). ui-tests sets it for a lane whose driver is `app`, with
`LEANNATIVE_SIMULATOR` (the device), `LEANNATIVE_BUNDLE_ID` and `LEANNATIVE_DISPLAY` (the screen to capture).

With `LEANNATIVE_DRIVER=wire` there is no simulator at all: the journeys executable runs the app itself, compiled
into it, as a child process answering from its view tree (LeanNative.Journey.Wire; the executable's `main` passes
the app as `wire`). A step costs a tree walk; what that does not test is the renderer and the shell.

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

/-- Who carries out the steps: XCTest's LNDriver, the app's LNAppDriver with the host doing the rest, or the app
itself, headless (LeanNative.Journey.Wire). -/
inductive Mode where
  | xctest
  | app
  | wire
  deriving BEq, Repr

/-- The app itself, for `Mode.wire`: `LeanNative.Journey.Wire.app myApp`. -/
structure WireApp where
  /-- Runs the app headless as the driver, connected to the host on this port, until the journey ends it. -/
  serve : UInt16 → IO Unit

/-- A connection to a driver. -/
structure Link where
  socket : TCP.Socket.Client
  /-- bytes received past the last answer read -/
  pending : IO.Ref ByteArray

/-- The app's simulator, for `Mode.app`. -/
structure Device where
  udid : String
  bundle : String
  /-- `simctl io --display`: the screen the app is on; none: simctl's default -/
  display : Option String

/-- The connection to the driver. -/
structure Driver where
  mode : Mode
  /-- XCTest's driver, connected once; the app's, connected again by each launch (none while it is not running) -/
  link : IO.Ref (Option Link)
  server : TCP.Socket.Server
  device : Option Device
  /-- `Mode.wire`: the running app's process, and where its files go -/
  child : IO.Ref (Option (IO.Process.Child {}))
  wireDir : Option String
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

private partial def readLine (d : Link) : IO String := do
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
    | none => failure "the driver closed the connection (the UI test ended, or the app: see xcodebuild.log, journey.log)"

private def accept (server : TCP.Socket.Server) (waitMs : Nat) (who : String) : IO TCP.Socket.Client := do
  let deadline := (← IO.monoMsNow) + waitMs
  repeat
    if let some c ← server.tryAccept then return c
    if (← IO.monoMsNow) ≥ deadline then failure s!"{who} did not connect within {waitMs / 1000} s"
    IO.sleep 50
  failure "unreachable"

/-- `xcrun simctl …`; its output, or the journey fails with it. -/
private def simctl (args : Array String) (env : Array (String × Option String) := #[]) : IO String := do
  let out ← IO.Process.output { cmd := "xcrun", args := #["simctl"] ++ args, env }
  unless out.exitCode == 0 do failure s!"simctl {" ".intercalate args.toList}: {out.stderr.trimAscii}"
  return out.stdout

private def okJson : Json := Json.mkObj [("ok", true)]

/-- What the host does itself when the app drives (`Mode.app`): launch, terminate, activate, shot, log, fail;
none for what the app answers. -/
private def hostAnswer (d : Driver) (dev : Device) (op : String) (fields : List (String × Json)) : IO (Option Json) := do
  let field (k : String) := (fields.lookup k).getD Json.null
  match op with
  | "launch" =>
    d.link.set none
    let env : Array (String × Option String) := match (field "env").getObj? with
      | .ok kvs => kvs.foldl (init := #[]) fun acc (k : String) (v : Json) =>
          match v.getStr? with | .ok s => acc.push (s!"SIMCTL_CHILD_{k}", some s) | .error _ => acc
      | .error _ => #[]
    let port := (← d.server.getSockName).port
    discard <| simctl #["launch", "--terminate-running-process", dev.udid, dev.bundle]
      (env.push ("SIMCTL_CHILD_LEANNATIVE_APP_DRIVER_PORT", some s!"{port}"))
    let socket ← accept d.server 60000 "the app's driver (LNAppDriver: a Debug build?)"
    d.link.set (some { socket, pending := ← IO.mkRef .empty })
    return some okJson
  | "terminate" =>
    d.link.set none
    discard <| (simctl #["terminate", dev.udid, dev.bundle]).toBaseIO
    return some okJson
  -- a running app is brought to the front, not launched again
  | "activate" => discard <| simctl #["launch", dev.udid, dev.bundle]; return some okJson
  | "shot" =>
    let some dir := (field "directory").getStr?.toOption | return some okJson
    let display := dev.display.toArray.map (s!"--display={·}")
    discard <| simctl (#["io", dev.udid, "screenshot", "--type=png"] ++ display ++ #[s!"{dir}/{(field "name").getStr?.toOption.getD "shot"}.png"])
    return some okJson
  | "log" | "fail" => return some okJson
  | "end" => if (← d.link.get).isNone then return some okJson else return none
  | _ => return none

/-- What the host does itself when the app runs headless (`Mode.wire`): launch (the journeys executable again, as
`--wire-app <port>`, with the environment asked for), terminate, end; none for what the app answers (`shot` and
`activate` among them). -/
private def wireAnswer (d : Driver) (dir : String) (op : String) (fields : List (String × Json)) : IO (Option Json) := do
  let field (k : String) := (fields.lookup k).getD Json.null
  let stop : IO Unit := do
    if let some c ← d.child.get then
      d.child.set none
      try c.kill catch _ => pure ()
      discard <| c.wait
    d.link.set none
  match op with
  | "launch" =>
    stop
    let env : Array (String × Option String) := match (field "env").getObj? with
      | .ok kvs => kvs.foldl (init := #[]) fun acc (k : String) (v : Json) =>
          match v.getStr? with | .ok s => acc.push (k, some s) | .error _ => acc
      | .error _ => #[]
    let port := (← d.server.getSockName).port
    IO.FS.createDirAll dir
    let child ← IO.Process.spawn { cmd := (← IO.appPath).toString, args := #["--wire-app", s!"{port}"],
                                   env := env.push ("LEANNATIVE_WIRE_DIR", some dir) }
    d.child.set (some child)
    let socket ← accept d.server 60000 "the app (LeanNative.Journey.Wire.serve)"
    d.link.set (some { socket, pending := ← IO.mkRef .empty })
    return some okJson
  | "terminate" => stop; return some okJson
  | "end" => if (← d.link.get).isNone then return some okJson else return none
  | _ => return none

/-- One command to the driver and its answer; a refusal (`ok: false`) fails the journey with the driver's reason. -/
def request (op : String) (fields : List (String × Json) := []) : UI Json := do
  let d ← read
  if let some dev := d.device then
    if let some j ← hostAnswer d dev op fields then return j
  if let some dir := d.wireDir then
    if let some j ← wireAnswer d dir op fields then return j
  let some l ← d.link.get | failure s!"{op}: the app is not running (launch it first)"
  let line := (Json.mkObj (("op", Json.str op) :: fields)).compress ++ "\n"
  (l.socket.send line.toUTF8).block
  let answer ← readLine l
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

/-- Holds the element down for `seconds` (the same checks as `tap`): a stepper's button repeats while held, which
reaches a far value in seconds rather than one tap per step. -/
def press (f : Find) (seconds : Float) : UI Unit :=
  discard <| request "press" [("find", f.toJson), ("seconds", toJson seconds)]

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

/-- Scrolls until the element can be tapped; whether it can. When it cannot, the log says why if the
driver does (the app's own driver: where it is and what a touch there reaches). -/
def scrollTo (f : Find) : UI Bool := do
  let j ← request "scroll" [("find", f.toJson)]
  let hittable ← bool j "hittable"
  if !hittable then
    if let .ok why := j.getObjValAs? String "why" then say s!"  {f.describe} cannot be tapped: {why}"
  return hittable

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

/-- An app's journey executable: `main := Journey.main [j₁, j₂, …] args (wire := some (Wire.app app))`, run by framework/native/ci/ui-tests as
`<exe> [journey names…] <evidence dir>` (all of them when no name is given; UI_JOURNEY="<exe> <name>" runs one). It listens on 127.0.0.1, writes the
port to `<dir>/driver-port`, waits for the driver (LEANNATIVE_DRIVER_WAIT seconds, default 3600: xcodebuild
builds the tests first), runs the journeys in order (one that fails is reported to the driver as a test failure,
and the next still runs), and writes `<dir>/journeys.json` (each journey's result, time and screenshots). 1 if any failed.
With `LEANNATIVE_DRIVER=wire` (and `wire` given) the app runs headless in a child of this executable
(`<exe> --wire-app <port>`, which this `main` answers by serving the app). -/
def main (journeys : List Journey) (args : List String) (wire : Option WireApp := none) : IO UInt32 := do
  if let ["--wire-app", port] := args then
    match wire, port.toNat? with
    | some w, some p => w.serve p.toUInt16; return 0
    | none, _ => IO.eprintln "--wire-app: this executable's journeys were given no app (Journey.main's wire)"; return 2
    | _, none => IO.eprintln s!"--wire-app: not a port: {port}"; return 2
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
  let driver := (← IO.getEnv "LEANNATIVE_DRIVER").getD "xctest"
  let device ← if driver == "app" then
      match ← IO.getEnv "LEANNATIVE_SIMULATOR", ← IO.getEnv "LEANNATIVE_BUNDLE_ID" with
      | some udid, some bundle => pure (some { udid, bundle, display := (← IO.getEnv "LEANNATIVE_DISPLAY").filter (· != "") : Device })
      | _, _ => IO.eprintln "LEANNATIVE_DRIVER=app needs LEANNATIVE_SIMULATOR and LEANNATIVE_BUNDLE_ID"; return 2
    else pure none
  let wireDir ← if driver == "wire" then
      if wire.isNone then IO.eprintln "LEANNATIVE_DRIVER=wire: this executable's journeys were given no app (Journey.main's wire)"; return 2
      pure (some (dir / "wire").toString)
    else pure none
  unless driver == "xctest" || driver == "app" || driver == "wire" do
    IO.eprintln s!"LEANNATIVE_DRIVER: xctest, app or wire, not {driver}"; return 2
  let link ← IO.mkRef none
  if device.isNone && wireDir.isNone then
    -- written whole, then renamed: ui-tests reads it as soon as it exists
    IO.FS.writeFile (dir / "driver-port.tmp") s!"{port}\n"
    IO.FS.rename (dir / "driver-port.tmp") (dir / "driver-port")
    say s!"journeys: listening on 127.0.0.1:{port}"
    let waitSecs := ((← IO.getEnv "LEANNATIVE_DRIVER_WAIT").bind String.toNat?).getD 3600
    let .ok socket ← (accept server (waitSecs * 1000) "the driver (did xcodebuild run LNDriver/testDrive?)").toBaseIO
      | say s!"journeys: the driver did not connect within {waitSecs} s (did xcodebuild run LNDriver/testDrive? xcodebuild.log)"; return 1
    link.set (some { socket, pending := ← IO.mkRef .empty })
  else if wireDir.isSome then
    say s!"journeys: the app itself, headless, on 127.0.0.1:{port}"
  else
    say s!"journeys: the app's driver, on 127.0.0.1:{port}"
  let d : Driver := { mode := if device.isSome then .app else if wireDir.isSome then .wire else .xctest, link, server, device,
                      child := ← IO.mkRef none, wireDir, screenshots := some shots.toString, taken := ← IO.mkRef #[] }
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
  if let some c ← d.child.get then
    try c.kill catch _ => pure ()
    discard <| c.wait
  IO.FS.writeFile (dir / "journeys.json") ((Json.arr results).pretty ++ "\n")
  say s!"journeys: {chosen.length - failed} passed, {failed} failed"
  return if failed == 0 then 0 else 1

end LeanNative.Journey
