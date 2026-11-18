import LeanNative.Native.Client.Auth
import LeanNative.Native.Client.Keychain
import LeanNative.Native.Client.Http
import LeanNative.Native.Client.HttpRequest
import LeanNative.Native.Client.CloudKit
import LeanNative.Native.Client.Bluetooth
import LeanNative.Native.Client.WebAuth
import LeanNative.Native.Client.Push
import LeanNative.Journey.Wire
import LeanNativeShell.Capabilities

/-! # The typed clients against wire fixtures and a fake shell

`fixtures/clients.json` is written from the capability table, apart from the decoders: each case names
a request built here, the arguments it must send, an answer, and the expected result. Every capability
a fixture names must be one the shell offers (`LeanNativeShell.capabilities`). Then a fake `Effects` answers
scripted replies, for the clients run end to end: the request reaches `ask`, unknown capabilities, and
an app's cleanup after a failure. And the headless driver's fake shell (`Journey.Wire.Shell`) answers the
clients for an item behind the person's presence: refused without a kept authentication, read under one,
refused again once it has ended. Run from framework/lean (the fixture path is relative). -/

open Lean LeanNative.Native LeanNative.Native.Client

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

/-- An item behind the person's presence, and a kept authentication's id as the shell gives one. -/
def seed : Keychain.Item := { key := "seed", service := some "org.example.app", access := .userPresence }
def kept : String := "5C2B4E0E-6C0B-4F27-9B43-0B2B1C3A7D11"

def addedJson : Keychain.Added → Json
  | .added => Json.str "added"
  | .alreadyExists => Json.str "alreadyExists"

def cases : List (String × Case) := [
  ("auth", .of (Auth.authenticate "Unlock the vault") fun s => Json.mkObj [("note", optJson (s.note.map Json.str))]),
  ("auth.keep", .of (Auth.authenticate "Send 0.1 BTC" (keep := some 30)) fun s =>
    Json.mkObj [("note", optJson (s.note.map Json.str)), ("context", optJson (s.context.map Json.str))]),
  ("auth.end", .of (Auth.end kept) unit),
  ("webauth", .of (WebAuth.start { url := "https://id.example.com/authorize?client_id=c&state=s", callback := .https "app.example.com" "/oauth/callback" }) Json.str),
  ("webauth.scheme", .of (WebAuth.start { url := "https://id.example.com/authorize", callback := .scheme "exampleapp", ephemeral := true }) Json.str),
  ("keychain.get", .of (Keychain.get item) fun b => Json.mkObj [("bytes", optJson (b.map (Json.str ∘ hexOf)))]),
  ("keychain.getText", .of (Keychain.getText item) fun t => Json.mkObj [("text", optJson (t.map Json.str))]),
  ("keychain.set", .of (Keychain.set { item with synchronizable := true } (ByteArray.mk #[0, 255])) unit),
  ("keychain.add", .of (Keychain.add item (ByteArray.mk #[1])) fun
    | .added => Json.str "added"
    | .alreadyExists => Json.str "alreadyExists"),
  ("keychain.delete", .of (Keychain.delete item) unit),
  ("keychain.clear", .of (Keychain.clear "org.example.test") unit),
  ("keychain.get.context", .of (Keychain.get seed (context := some kept)) fun b => Json.mkObj [("bytes", optJson (b.map (Json.str ∘ hexOf)))]),
  ("keychain.get.presence", .of (Keychain.get seed) fun b => Json.mkObj [("bytes", optJson (b.map (Json.str ∘ hexOf)))]),
  ("keychain.getText.context", .of (Keychain.getText seed (context := some kept)) fun t => Json.mkObj [("text", optJson (t.map Json.str))]),
  ("keychain.add.presence", .of (Keychain.add seed (ByteArray.mk #[1])) addedJson),
  ("keychain.add.presence.sync", .of (Keychain.add { seed with synchronizable := true } (ByteArray.mk #[1])) addedJson),
  ("keychain.addApplied", .of (Keychain.addApplied seed (ByteArray.mk #[1])) fun (a, access) =>
    Json.mkObj [("added", addedJson a), ("access", Json.str access.name)]),
  ("keychain.set.presence", .of (Keychain.set seed (ByteArray.mk #[0, 255])) unit),
  -- `protect` asks for the person's presence whatever the item says
  ("keychain.protect", .of (Keychain.protect item) fun changed => Json.mkObj [("changed", Json.bool changed)]),
  ("keychain.attributes", .of (Keychain.attributes item) fun a => optJson (a.map fun a =>
    Json.mkObj [("accessible", optJson (a.accessible.map Json.str)), ("userPresence", Json.bool a.userPresence),
                ("synchronizable", Json.bool a.synchronizable)])),
  ("http.get", .of (Http.get { url := "https://example.com/a", maxBytes := 100, timeout := some 5, accept := some "application/json",
                               socks := some ("127.0.0.1", 9050) })
    fun r => Json.mkObj [("status", toJson r.status), ("body", Json.str (hexOf r.body))]),
  ("http.get.plain", .of (Http.get { url := "https://example.com/" })
    fun r => Json.mkObj [("status", toJson r.status), ("body", Json.str (hexOf r.body))]),
  ("http.request", .of (Http.send ({ url := "https://example.com/api/login", httpMethod := "POST", headers := [("Content-Type", "application/json")], body := some "{}".toUTF8 } : Http.SendRequest))
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
  ("cloudkit.loadMany", .of (CloudKit.loadMany #["n1", "n2", "n3"] (files := true) (maxBytes := some 1024)) fun m =>
    Json.mkObj [("directory", optJson (m.directory.map Json.str)),
      ("records", Json.arr (m.records.map fun (name, l) => match l with
        | .record r asset file => Json.mkObj [("name", name), ("record", recordJson r), ("asset", optJson (asset.map (Json.str ∘ hexOf))), ("file", optJson (file.map Json.str))]
        | .failed e => Json.mkObj [("name", name), ("error", e.name), ("kind", e.kind.name), ("retryAfter", optJson (CloudKit.Error.retryAfter? e |>.map toJson))]))]),
  ("cloudkit.loadMany.hex", .of (CloudKit.loadMany #["n1"]) fun m =>
    Json.arr (m.records.map fun (name, l) => match l with
      | .record _ asset _ => Json.mkObj [("name", name), ("asset", optJson (asset.map (Json.str ∘ hexOf)))]
      | .failed e => Json.mkObj [("name", name), ("error", e.name)])),
  ("cloudkit.delete", .of (CloudKit.delete "n1") unit),
  ("ble.state", .of Bluetooth.state fun s => Json.str (match s with
    | .poweredOn => "poweredOn" | .poweredOff => "poweredOff" | .unauthorized => "unauthorized"
    | .unsupported => "unsupported" | .resetting => "resetting" | .unknown => "unknown")),
  ("ble.scan", .of (Bluetooth.scan ["13D63400-2C97-0004-0000-4C6564676572"] (some 4))
    fun ds => Json.arr (ds.map fun d => Json.mkObj ([("id", Json.str d.id)] ++ (d.name.map fun n => [("name", Json.str n)]).getD [] ++
      (d.rssi.map fun r => [("rssi", toJson r)]).getD []))),
  ("ble.connect", .of (Bluetooth.connect ["13D63400-2C97-0004-0000-4C6564676572"] (some 45))
    fun c => Json.mkObj ([("id", Json.str c.id)] ++ (c.name.map fun n => [("name", Json.str n)]).getD [] ++
      [("service", Json.str c.service), ("characteristics", Json.arr (c.characteristics.map Json.str))])),
  ("ble.subscribe", .of (Bluetooth.subscribe "p1" "c1" (some 90)) unit),
  ("ble.write", .of (Bluetooth.write "p1" "c2" (ByteArray.mk #[8, 0]) (timeout := some 15)) unit),
  ("ble.read", .of (Bluetooth.read "p1" "c1" (some 30)) (Json.str ∘ hexOf)),
  ("ble.close", .of (Bluetooth.close "p1") unit),
  ("push.register", .of Push.register fun t => Json.mkObj [("hex", Json.str t.hex), ("environment", Json.str t.environment.name)]),
  ("push.unregister", .of Push.unregister unit),
  ("push.permission", .of Push.permission fun p => Json.mkObj [("status", Json.str p.name), ("shows", Json.bool p.shows)]),
  ("push.ask", .of (Push.ask (badge := false)) Json.bool),
  ("push.complete", .of (Push.complete 7 .newData) Json.bool) ]

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
  let offered := LeanNativeShell.capabilities.map (·.name)
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

/-- The headless driver's fake shell as an `Effects`: every `ask` is answered by `Journey.Wire.Shell`, as it
answers an app under `LEANNATIVE_DRIVER=wire`. -/
def wireEffects (sh : LeanNative.Journey.Wire.Shell) : Effects Unit :=
  { post := fun _ => pure ()
    cap := fun name args k => do discard <| pure (k (← sh.answer name args))
    ask := fun name args => do pure (.pure (← sh.answer name args)) }

/-- Refused as a read the Keychain would have had to ask the person for (`errSecInteractionNotAllowed`). -/
def refused (r : Result α) : Bool := match r with
  | .error e => e.kind == .failed && e.code == some Keychain.errSecInteractionNotAllowed
  | .ok _ => false

/-- An item behind the person's presence, against the fake shell: the Keychain asks nobody, so a read is refused
unless the request names a kept authentication that lives. -/
def userPresence : IO Unit := do
  let dir ← IO.FS.createTempDir
  let sh ← LeanNative.Journey.Wire.Shell.new dir
  let fx := wireEffects sh
  let bytes := ByteArray.mk #[1, 2, 3]
  let read (r : Result (Option ByteArray)) : Bool := match r with
    | .ok (some b) => b == bytes
    | _ => false
  let flagged? (i : Keychain.Item) : IO (Option Bool) := do
    match ← (Keychain.attributes i).call fx with
    | .ok (some a) => pure (some a.userPresence)
    | _ => pure none
  let seed : Keychain.Item := { key := "seed", service := some "org.example.test", access := .userPresence }
  check "presence: an item added behind it, and the shell says so" ((← (Keychain.addApplied seed bytes).call fx) matches .ok (.added, .userPresence))
  check "presence: its attributes report it, and not its value" (match ← (Keychain.attributes seed).call fx with
    | .ok (some a) => a.userPresence && !a.synchronizable && a.accessible == some "whenUnlockedThisDeviceOnly" && a.access == .userPresence
    | _ => false)
  check "presence: a read without a context is refused" (refused (← (Keychain.get seed).call fx))
  check "presence: a read naming a context that never was is refused" (refused (← (Keychain.get seed (context := some "nobody")).call fx))
  check "presence: an authentication without keep keeps nothing" ((← (Auth.authenticate "Read the seed").call fx) matches .ok { note := none, context := none })
  let some context := (match ← (Auth.authenticate "Read the seed" (keep := some 30)).call fx with
    | .ok s => s.context
    | .error _ => none) | check "presence: a kept authentication has a context" false
  check "presence: a read under a kept authentication" (read (← (Keychain.get seed (context := some context)).call fx))
  check "presence: a second read under the same one" (read (← (Keychain.get seed (context := some context)).call fx))
  check "presence: the text under it too" (match ← (Keychain.getText { seed with key := "words" } (context := some context)).call fx with
    | .ok none => true
    | _ => false)
  check "presence: auth.end" ((← (Auth.end context).call fx) matches .ok ())
  check "presence: refused again after auth.end" (refused (← (Keychain.get seed (context := some context)).call fx))
  check "presence: ending it twice is not an error" ((← (Auth.end context).call fx) matches .ok ())
  -- each kept authentication its own id, and one's end is not another's
  let ids ← (List.range 2).mapM fun _ => do
    return (match ← (Auth.authenticate "Read the seed" (keep := some 30)).call fx with | .ok s => s.context | .error _ => none).getD ""
  check "presence: each kept authentication its own id" (ids.all (· != "") && ids.eraseDups.length == 2 && !ids.contains context)
  discard <| (Auth.end (ids.headD "")).call fx
  check "presence: one's end is not another's" (refused (← (Keychain.get seed (context := some (ids.headD ""))).call fx)
    && read (← (Keychain.get seed (context := some (ids.getLastD ""))).call fx))
  -- the app's going to the background ends every one
  sh.endContexts
  check "presence: refused once the app went to the background" (refused (← (Keychain.get seed (context := some (ids.getLastD ""))).call fx))
  -- what `set` and `add` refuse, each leaving the item as it was
  check "presence: set over such an item is refused" (refused (← (Keychain.set { seed with access := .unlocked } (ByteArray.mk #[9])).call fx))
  check "presence: set asking for it is refused" (match ← (Keychain.set { seed with key := "new" } bytes).call fx with
    | .error e => e.code == some (-50)
    | .ok _ => false)
  check "presence: and made no item" ((← (Keychain.attributes { seed with key := "new" }).call fx) matches .ok none)
  check "presence: add over it leaves it" ((← (Keychain.add seed (ByteArray.mk #[9])).call fx) matches .ok .alreadyExists)
  check "presence: a synchronizable item cannot be behind it" (match ← (Keychain.add { seed with key := "cloud", synchronizable := true } bytes).call fx with
    | .error e => e.code == some (-50)
    | .ok _ => false)
  -- protect: an item that is there, upgraded in place
  let wallet : Keychain.Item := { key := "wallet", service := some "org.example.test" }
  discard <| (Keychain.add wallet bytes).call fx
  check "protect: an unflagged item reads without a context" (read (← (Keychain.get wallet).call fx) && (← flagged? wallet) == some false)
  check "protect: flags it" ((← (Keychain.protect wallet).call fx) matches .ok true)
  check "protect: its attributes report it" ((← flagged? wallet) == some true)
  check "protect: idempotent" ((← (Keychain.protect wallet).call fx) matches .ok false)
  check "protect: a read without a context is now refused" (refused (← (Keychain.get wallet).call fx))
  let context := (match ← (Auth.authenticate "Read the wallet" (keep := some 30)).call fx with | .ok s => s.context | .error _ => none).getD ""
  check "protect: the value is the one it had" (read (← (Keychain.get wallet (context := some context)).call fx))
  check "protect: no such item" (match ← (Keychain.protect { wallet with key := "nothing" }).call fx with
    | .error e => e.code == some Keychain.errSecItemNotFound
    | .ok _ => false)
  discard <| (Keychain.set { wallet with key := "cloud", synchronizable := true } bytes).call fx
  check "protect: a synchronizable item is refused, and stays as it was" (
    (match ← (Keychain.protect { wallet with key := "cloud", synchronizable := true }).call fx with
      | .error e => e.code == some (-50)
      | .ok _ => false) && (← flagged? { wallet with key := "cloud", synchronizable := true }) == some false)
  -- the Keychain is a file: a relaunch finds the items as they were, and no kept authentication
  let again ← LeanNative.Journey.Wire.Shell.new dir
  let fx := wireEffects again
  check "relaunch: the item is still behind it" (refused (← (Keychain.get wallet).call fx)
    && (match ← (Keychain.attributes wallet).call fx with | .ok (some a) => a.userPresence | _ => false))
  check "relaunch: no kept authentication survives" (refused (← (Keychain.get wallet (context := some context)).call fx))
  -- a file written before there were such items still loads, its items not behind it
  IO.FS.writeFile again.keychainFile "[{\"service\": \"org.example.test\", \"key\": \"old\", \"synchronizable\": false, \"hex\": \"010203\"}]"
  let old ← LeanNative.Journey.Wire.Shell.new dir
  check "an older file: its item loads, not behind it" (read (← (Keychain.get { wallet with key := "old" }).call (wireEffects old)))
  IO.FS.removeDirAll dir

/-- The push events an app reads from `App.system`, as the shell posts them (`LeanNativeShell.Push`), and the
shell's bookkeeping of notices received. -/
def pushEvents : IO Unit := do
  let payload := Json.mkObj [("aps", Json.mkObj [("content-available", (1 : Nat))]), ("id", "m1")]
  check "push: a notice received, as the shell posts it" (match Push.event? (LeanNativeShell.PendingNotices.event 3 "background" payload) with
    | some (.received 3 "background" p) => p == payload
    | _ => false)
  check "push: the shell about to answer for the app" (match Push.event? (Json.mkObj [("pushExpired", Json.mkObj [("tag", (3 : Nat))])]) with
    | some (.expired 3) => true
    | _ => false)
  check "push: a notice arriving in front" (match Push.event? (Json.mkObj [("pushPresented", Json.mkObj [("payload", payload)])]) with
    | some (.presented p) => p == payload
    | _ => false)
  check "push: a notice tapped" (match Push.event? (Json.mkObj [("pushOpened", Json.mkObj [("payload", payload)])]) with
    | some (.opened p) => p == payload
    | _ => false)
  check "push: a notice without a tag is no event, and another system event is none" (
    (Push.event? (Json.mkObj [("push", Json.mkObj [("state", "active")])])).isNone &&
    (Push.event? (Json.mkObj [("scene", "active")])).isNone)
  -- each notice has its own tag, and iOS is answered once for each: by the app, or by the shell when the
  -- time is up, never both
  let (s1, t1) := ({} : LeanNativeShell.PendingNotices).received
  let (s2, t2) := s1.received
  check "push: each notice its own tag" (t1 == 1 && t2 == 2)
  let (s3, first) := s2.finish t1
  check "push: answered once, and the other notice still waits" (first && !(s3.finish t1).2 && (s3.finish t2).2)
  check "push: a tag never given is not pending" (!(s2.finish 9).2)

def main (args : List String) : IO UInt32 := do
  fixtures (args.headD "LeanNativeTest/fixtures/clients.json")
  endToEnd
  userPresence
  pushEvents
  let n ← failures.get
  IO.println (if n == 0 then "clients: all passed" else s!"clients: {n} failed")
  return if n == 0 then 0 else 1
