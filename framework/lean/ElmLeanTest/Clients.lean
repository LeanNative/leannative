import ElmLean.Native.Client.Auth
import ElmLean.Native.Client.Keychain
import ElmLean.Native.Client.Http
import ElmLean.Native.Client.CloudKit
import ElmLean.Native.Client.Bluetooth
import ElmShell.Capabilities

/-! # The typed clients against wire fixtures and a fake shell

`fixtures/clients.json` is written from the capability table, apart from the decoders: each case names
a request built here, the arguments it must send, an answer, and the expected result. Every capability
a fixture names must be one the shell offers (`ElmShell.capabilities`). Then a fake `Effects` answers
scripted replies, for the clients run end to end: the request reaches `ask`, unknown capabilities, and
an app's cleanup after a failure. Run from framework/lean (the fixture path is relative). -/

open Lean ElmLean.Native ElmLean.Native.Client

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) (why : String := "") : IO Unit := do
  if ok then IO.println s!"ok   {name}"
  else IO.println s!"FAIL {name}{if why.isEmpty then "" else s!": {why}"}"; failures.modify (· + 1)

/-- JSON equality with numbers compared by value (`3` = `3.0`). -/
partial def same : Json → Json → Bool
  | .num a, .num b => a.toFloat == b.toFloat
  | .obj a, .obj b =>
    a.toList.length == b.toList.length && a.toList.all fun (k, v) => match b.get? k with
      | some w => same v w
      | none => false
  | .arr a, .arr b => a.size == b.size && (a.zip b).all fun (x, y) => same x y
  | a, b => a == b

def optJson (o : Option Json) : Json := o.getD .null

def recordJson (r : CloudKit.Record) : Json :=
  Json.mkObj [("name", r.name), ("type", r.type), ("modified", optJson (r.modified.map toJson)), ("tag", optJson (r.tag.map Json.str)),
              ("fields", Json.mkObj (r.fields.map fun (k, v) => (k, v.toJson)))]

/-- A request this test builds, and how its result renders for comparison with a fixture. -/
structure Case where
  capability : String
  args : Json
  read : Json → Except Error Json

def Case.of (r : Client.Request α) (render : α → Json) : Case :=
  { capability := r.capability, args := r.args, read := fun j => (r.read j).map render }

def unit : Unit → Json := fun _ => Json.mkObj []

def item : Keychain.Item := { key := "wallet", service := some "org.example.app" }

def cases : List (String × Case) := [
  ("auth", .of (Auth.authenticate "Unlock the vault") fun s => Json.mkObj [("note", optJson (s.note.map Json.str))]),
  ("keychain.get", .of (Keychain.get item) fun b => Json.mkObj [("bytes", optJson (b.map (Json.str ∘ hexOf)))]),
  ("keychain.getText", .of (Keychain.getText item) fun t => Json.mkObj [("text", optJson (t.map Json.str))]),
  ("keychain.set", .of (Keychain.set { item with synchronizable := true } (ByteArray.mk #[0, 255])) unit),
  ("keychain.add", .of (Keychain.add item (ByteArray.mk #[1])) fun
    | .added => Json.str "added"
    | .alreadyExists => Json.str "alreadyExists"),
  ("keychain.delete", .of (Keychain.delete item) unit),
  ("keychain.clear", .of (Keychain.clear "org.example.test") unit),
  ("http.get", .of (Http.get { url := "https://example.com/a", maxBytes := 100, timeout := some 5, accept := some "application/json",
                               socks := some ("127.0.0.1", 9050) })
    fun r => Json.mkObj [("status", toJson r.status), ("body", Json.str (hexOf r.body))]),
  ("http.get.plain", .of (Http.get { url := "https://example.com/" })
    fun r => Json.mkObj [("status", toJson r.status), ("body", Json.str (hexOf r.body))]),
  ("cloudkit.account", .of (CloudKit.account (some "iCloud.org.example.app")) fun a =>
    let status := match a.status with
      | .available => "available" | .noAccount => "noAccount" | .restricted => "restricted"
      | .couldNotDetermine => "couldNotDetermine" | .temporarilyUnavailable => "temporarilyUnavailable"
    Json.mkObj [("status", Json.str status), ("user", optJson (a.user.map Json.str))]),
  ("cloudkit.query", .of (CloudKit.query { type := "Note", equals := [("network", .str "signet")], sortBy := some "savedAt",
                                           ascending := false, keys := some ["network", "savedAt"], limit := some 500 })
    fun q => Json.mkObj [("records", Json.arr (q.records.map recordJson)), ("more", Json.bool q.more)]),
  ("cloudkit.save", .of (CloudKit.save { type := "Note", name := "n1", fields := [("network", .str "signet"), ("savedAt", .date 1.5)],
                                         asset := some (ByteArray.mk #[1, 2]), assetField := some "payload" }) recordJson),
  ("cloudkit.load", .of (CloudKit.load "n1" (maxBytes := some 1024) (assetField := some "payload"))
    fun (r, a) => Json.mkObj [("record", recordJson r), ("asset", optJson (a.map (Json.str ∘ hexOf)))]),
  ("cloudkit.delete", .of (CloudKit.delete "n1") unit),
  ("ble.state", .of Bluetooth.state fun s => Json.str (match s with
    | .poweredOn => "poweredOn" | .poweredOff => "poweredOff" | .unauthorized => "unauthorized"
    | .unsupported => "unsupported" | .resetting => "resetting" | .unknown => "unknown")),
  ("ble.connect", .of (Bluetooth.connect ["13D63400-2C97-0004-0000-4C6564676572"] (some 45))
    fun c => Json.mkObj [("id", Json.str c.id), ("service", Json.str c.service), ("characteristics", Json.arr (c.characteristics.map Json.str))]),
  ("ble.subscribe", .of (Bluetooth.subscribe "p1" "c1" (some 90)) unit),
  ("ble.write", .of (Bluetooth.write "p1" "c2" (ByteArray.mk #[8, 0]) (timeout := some 15)) unit),
  ("ble.read", .of (Bluetooth.read "p1" "c1" (some 30)) (Json.str ∘ hexOf)),
  ("ble.close", .of (Bluetooth.close "p1") unit) ]

def errorMatches (want : Json) (e : Error) : Bool :=
  let field (k : String) (have_ : Json) : Bool := match want.getObjVal? k with
    | .ok v => same v have_
    | .error _ => true
  field "kind" (Json.str e.kind.name) && field "name" (Json.str e.name) &&
    field "code" (optJson (e.code.map toJson)) && field "domain" (optJson (e.domain.map Json.str))

def fixtures (path : String) : IO Unit := do
  let doc ← match Json.parse (← IO.FS.readFile path) with
    | .ok j => pure j
    | .error e => throw (IO.userError s!"{path}: {e}")
  let some (.arr all) := (doc.getObjVal? "cases").toOption | throw (IO.userError s!"{path}: no cases")
  let offered := ElmShell.capabilities.map (·.name)
  let mut used : List String := []
  for c in all do
    let name := (c.getObjValAs? String "name").toOption.getD "?"
    let reqName := (c.getObjValAs? String "request").toOption.getD ""
    let some r := cases.lookup reqName | check name false s!"no request {reqName}"; continue
    used := reqName :: used
    if let .ok cap := c.getObjValAs? String "capability" then
      check s!"{name}: capability" (cap == r.capability && offered.contains cap) s!"{r.capability}, offered {offered.contains cap}"
    if let .ok args := c.getObjVal? "args" then
      check s!"{name}: arguments" (same args r.args) r.args.compress
    let reply := (c.getObjVal? "reply").toOption.getD .null
    let expect := (c.getObjVal? "expect").toOption.getD .null
    match r.read reply, expect.getObjVal? "ok", expect.getObjVal? "error" with
    | .ok got, .ok want, _ => check name (same got want) s!"got {got.compress}"
    | .error e, _, .ok want =>
      let retry := match expect.getObjVal? "retryAfter" with
        | .ok v => same v (optJson (CloudKit.Error.retryAfter? e |>.map toJson))
        | .error _ => true
      check name (errorMatches want e && e.capability == r.capability && e.reply == reply && retry) (toString e)
    | .ok got, _, _ => check name false s!"expected an error, got {got.compress}"
    | .error e, _, _ => check name false s!"expected a result, got {e}"
  -- every request built here has a fixture, and every one the shell offers is named by a capability of the shell
  check "every request has a fixture" (cases.all fun (n, _) => used.contains n)
  check "every request is a capability the shell offers" (cases.all fun (_, r) => offered.contains r.capability)

/-- A fake shell: answers each `ask` with `respond name args`, and records what was asked. -/
def fakeShell (respond : String → Json → Json) : IO (Effects Unit × IO.Ref (Array (String × Json))) := do
  let asked ← IO.mkRef #[]
  let fx : Effects Unit :=
    { post := fun _ => pure ()
      cap := fun name args k => do asked.modify (·.push (name, args)); discard <| pure (k (respond name args))
      ask := fun name args => do asked.modify (·.push (name, args)); pure (.pure (respond name args)) }
  return (fx, asked)

def endToEnd : IO Unit := do
  -- a call reaches the shell with its capability and arguments, and its answer is read
  let (fx, asked) ← fakeShell fun
    | "keychain.add", _ => Json.mkObj [("ok", false), ("status", (-25299 : Int)), ("exists", true)]
    | name, _ => Json.mkObj [("error", Json.str s!"unknown capability {name}")]
  let r ← (Keychain.add item (ByteArray.mk #[7])).call fx
  check "call: asked once, as built" ((← asked.get) == #[("keychain.add", (Keychain.add item (ByteArray.mk #[7])).args)])
  check "call: an existing item is reported, not replaced" (r matches .ok .alreadyExists)
  -- a capability the shell does not have
  match ← (Bluetooth.state).call fx with
  | .error e => check "call: an unknown capability is unsupported" (e.kind == .unsupported && e.capability == "ble.state")
  | .ok _ => check "call: an unknown capability is unsupported" false
  -- an app's cleanup after a failure: connect succeeds, subscribe is refused, the connection is closed
  let (fx, asked) ← fakeShell fun
    | "ble.connect", _ => Json.mkObj [("ok", true), ("id", "p1"), ("service", "s"), ("characteristics", Json.arr #["n", "w"])]
    | "ble.subscribe", _ => Json.mkObj [("ok", false), ("error", "unauthorized")]
    | "ble.close", _ => Json.mkObj [("ok", true)]
    | _, _ => Json.mkObj [("error", "?")]
  let opened : IO (Result Bluetooth.Connection) := do
    match ← (Bluetooth.connect ["s"]).call fx with
    | .error e => pure (.error e)
    | .ok c =>
      match ← (Bluetooth.subscribe c.id "n").call fx with
      | .ok () => pure (.ok c)
      | .error e => discard <| (Bluetooth.close c.id).call fx; pure (.error e)
  let r ← opened
  check "cleanup: a refused subscribe is denied, and the connection closed"
    ((match r with | .error e => e.kind == .denied && e.name == "unauthorized" | .ok _ => false) &&
     (← asked.get).map (·.1) == #["ble.connect", "ble.subscribe", "ble.close"])
  -- an asynchronous request: the answer comes through the task, a cancellation stays a cancellation
  let (fx, _) ← fakeShell fun _ _ => Json.mkObj [("ok", false), ("error", "Canceled."), ("name", "userCancel"), ("code", (-2 : Int))]
  let t ← (Auth.authenticate "x").run fx
  match ← IO.wait t with
  | .error e => check "request: a cancelled authentication is not a denial" (e.kind == .cancelled && e.code == some (-2))
  | .ok _ => check "request: a cancelled authentication is not a denial" false

def main (args : List String) : IO UInt32 := do
  fixtures (args.headD "ElmLeanTest/fixtures/clients.json")
  endToEnd
  let n ← failures.get
  IO.println (if n == 0 then "clients: all passed" else s!"clients: {n} failed")
  return if n == 0 then 0 else 1
