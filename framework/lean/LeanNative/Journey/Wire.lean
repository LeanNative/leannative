import Std.Sync.Mutex
import LeanNative.Native
import LeanNative.Journey
import LeanNative.Journey.Regex

/-! # The headless journey driver: the app's own view tree, no simulator

A LeanNative app is a `Wire` tree and a proven dispatcher: what a journey taps is a node with a path, and what
it reads is a string in that tree. So the same journey programs that drive the app in a simulator through
XCTest (`LNDriver.m`) can drive the app itself, compiled into the journeys executable, with nothing rendered:
`Mode.wire`.

The journeys executable (`Journey.main … (wire := some (Wire.app myApp))`) runs the app as a child process of
itself (`<exe> --wire-app <port>`, the environment of `launch` in its environment). The child runs
`Native.runtime` with a fake shell (`Shell`) answering the capabilities the real shell would
(`LeanNativeShell/Capabilities.lean`'s protocol: a Keychain in a file, authentication that says yes, paths under
`LEANNATIVE_WIRE_DIR`, a clipboard, no network, no Bluetooth, no iCloud account), connects to the host, and answers the driver's commands (`LNDriver.m` lists them) from the current view:

* an element is found as a person would see it: the selected tab's content, covered by the innermost sheet,
  covered by the alert on it. `id` is `Html.identified`; `tab`, `alert`, `button`, `nav`, `back` and `text` as
  the other drivers, `text` matched by `Journey.Regex`;
* its text is what XCTest reads from the view the identifier lands on (`LNIdentify`: the node's control, else its
  last label: a `labeled` row's value), or, for a container, its texts joined;
* a tap is the event the node advertises (`Wire.accepts`), sent through `Session.step` exactly as the shell
  sends a touch: a button's `click`, a toggle's `toggle`, a tab's or picker option's `select`, a stepper half's
  `select` of the next value, the back button's `dismiss`; `type` is `input`. A node that advertises no event is
  refused, as a disabled control is: a journey never "taps" a label here;
* `exists`, `text` and the readiness checks poll the view (the app's answers arrive through `drain`, which the
  child runs whenever the runtime has something queued);
* `shot` writes the visible tree as `<name>.wire.json` in the screenshots directory, in place of a PNG.

What this does not test: the renderer, real touches, scrolling, hit-testing, the system keyboard, the shell's
capabilities. Those are the simulator drivers' and the shell's own tests'. What it does test is everything the
journeys assert about the app against the world outside it (a node, a file), in seconds, on any Mac, in the
same job as the other headless tests. -/

namespace LeanNative.Journey.Wire
open Lean LeanNative LeanNative.Native Std.Async

/-! ## The fake shell -/

private def hexDigit (n : Nat) : Char := "0123456789abcdef".toList[n]!

def hexOf (b : ByteArray) : String :=
  String.ofList (b.toList.flatMap fun x => [hexDigit (x.toNat / 16), hexDigit (x.toNat % 16)])

def bytesOfHex? (s : String) : Option ByteArray := do
  let cs := s.toList
  if cs.length % 2 != 0 then none
  let digit (c : Char) : Option Nat :=
    if c.isDigit then some (c.toNat - '0'.toNat)
    else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
    else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
    else none
  let rec go : List Char → Option (List UInt8)
    | [] => some []
    | a :: b :: rest => do pure ((16 * (← digit a) + (← digit b)).toUInt8 :: (← go rest))
    | _ => none
  return ByteArray.mk (← go cs).toArray

/-- A Keychain item: service, key, whether it syncs. -/
structure KeychainItem where
  service : String
  key : String
  synchronizable : Bool
  deriving BEq, Repr

structure KeychainEntry where
  item : KeychainItem
  hex : String
  deriving Repr

/-- The fake shell's state: its files under `dir`, the Keychain kept in `dir/keychain.json` so that it survives a
relaunch as a device's does, the clipboard. -/
structure Shell where
  dir : System.FilePath
  keychain : IO.Ref (Array KeychainEntry)
  clipboard : IO.Ref (Option String)
  /-- An app's own answers, tried first: `none` for the default. -/
  override : String → Json → IO (Option Json) := fun _ _ => pure none

namespace Shell

def keychainFile (sh : Shell) : System.FilePath := sh.dir / "keychain.json"

def saveKeychain (sh : Shell) : IO Unit := do
  let entries ← sh.keychain.get
  let rows := entries.map fun e => Json.mkObj [("service", Json.str e.item.service), ("key", Json.str e.item.key),
    ("synchronizable", Json.bool e.item.synchronizable), ("hex", Json.str e.hex)]
  IO.FS.writeFile sh.keychainFile ((Json.arr rows).pretty ++ "\n")

def loadKeychain (path : System.FilePath) : IO (Array KeychainEntry) := do
  unless ← path.pathExists do return #[]
  match Json.parse (← IO.FS.readFile path) with
  | .error _ => return #[]
  | .ok j =>
    let rows := (j.getArr?).toOption.getD #[]
    return rows.filterMap fun r => do
      let service ← (r.getObjValAs? String "service").toOption
      let key ← (r.getObjValAs? String "key").toOption
      let hex ← (r.getObjValAs? String "hex").toOption
      let sync := (r.getObjValAs? Bool "synchronizable").toOption.getD false
      pure { item := { service, key, synchronizable := sync }, hex }

def new (dir : System.FilePath) (override : String → Json → IO (Option Json) := fun _ _ => pure none) : IO Shell := do
  IO.FS.createDirAll dir
  return { dir, keychain := ← IO.mkRef (← loadKeychain (dir / "keychain.json")), clipboard := ← IO.mkRef none, override }

private def str (args : Json) (k : String) : Option String := (args.getObjValAs? String k).toOption
private def flag (args : Json) (k : String) : Bool := (args.getObjValAs? Bool k).toOption.getD false

def errSecItemNotFound : Int := -25300
def errSecDuplicateItem : Int := -25299
def errSecParam : Int := -50

private def item (args : Json) : KeychainItem :=
  { service := (str args "service").getD "app", key := (str args "key").getD "", synchronizable := flag args "synchronizable" }

/-- `value` (UTF-8) or `hex`: the bytes an item is set to, as hex. -/
private def bytesArg (args : Json) : Option String :=
  match str args "hex" with
  | some h => if (bytesOfHex? h).isSome then some h else none
  | none => some (hexOf ((str args "value").getD "").toUTF8)

private def status (ok : Bool) (code : Int) : List (String × Json) :=
  [("ok", Json.bool ok), ("status", toJson (if ok then 0 else code))]

/-- The default answers, by the shell's protocol. -/
def defaultAnswer (sh : Shell) (name : String) (args : Json) : IO Json := do
  match name with
  | "auth" => return Json.mkObj [("ok", true)]
  | "build" => return Json.mkObj [("debug", true)]
  | "paths" =>
    let documents := sh.dir / "Documents"
    let support := sh.dir / "Library" / "Application Support"
    let tmp := sh.dir / "tmp"
    for d in [documents, support, tmp] do IO.FS.createDirAll d
    return Json.mkObj [("documents", Json.str documents.toString), ("support", Json.str support.toString), ("tmp", Json.str tmp.toString)]
  | "documents" =>
    let documents := sh.dir / "Documents"
    IO.FS.createDirAll documents
    return Json.mkObj [("path", Json.str documents.toString)]
  | "exclude-from-backup" => return Json.mkObj [("ok", true)]
  | "open" => return Json.mkObj [("ok", true)]
  | "clipboard.set" =>
    sh.clipboard.set (str args "text")
    return Json.mkObj [("ok", true)]
  | "clipboard.get" =>
    return Json.mkObj [("text", match ← sh.clipboard.get with | some t => Json.str t | none => Json.null)]
  | "keychain.get" =>
    let i := item args
    let entries ← sh.keychain.get
    match entries.find? (·.item == i) with
    | some e =>
      if flag args "hex" then return Json.mkObj [("hex", Json.str e.hex), ("status", toJson (0 : Int))]
      match String.fromUTF8? ((bytesOfHex? e.hex).getD .empty) with
      | some text => return Json.mkObj [("value", Json.str text), ("status", toJson (0 : Int))]
      | none => return Json.mkObj [("value", Json.null), ("status", toJson (0 : Int))]
    | none =>
      return Json.mkObj [(if flag args "hex" then "hex" else "value", Json.null), ("status", toJson errSecItemNotFound)]
  | "keychain.add" =>
    let i := item args
    let some hex := bytesArg args | return Json.mkObj (status false errSecParam ++ [("exists", Json.bool false)])
    let entries ← sh.keychain.get
    if entries.any (·.item == i) then return Json.mkObj (status false errSecDuplicateItem ++ [("exists", Json.bool true)])
    sh.keychain.set (entries.push { item := i, hex })
    sh.saveKeychain
    return Json.mkObj (status true 0 ++ [("exists", Json.bool false)])
  | "keychain.set" =>
    let i := item args
    let some hex := bytesArg args | return Json.mkObj (status false errSecParam)
    sh.keychain.modify fun es => (es.filter (·.item != i)).push { item := i, hex }
    sh.saveKeychain
    return Json.mkObj (status true 0)
  | "keychain.delete" =>
    let i := item args
    sh.keychain.modify (·.filter (·.item != i))
    sh.saveKeychain
    return Json.mkObj (status true 0)
  | "keychain.clear" =>
    let some service := str args "service" | return Json.mkObj (status false errSecParam)
    let sync := flag args "synchronizable"
    sh.keychain.modify (·.filter fun e => !(e.item.service == service && e.item.synchronizable == sync))
    sh.saveKeychain
    return Json.mkObj (status true 0)
  | "http.get" | "http.request" =>
    -- no network: the system's offline error, as the shell would relay it
    return Json.mkObj [("error", Json.str "The Internet connection appears to be offline."), ("code", toJson (-1009 : Int)),
                       ("domain", Json.str "NSURLErrorDomain")]
  | "ble.state" => return Json.mkObj [("state", Json.str "unsupported")]
  | "ble.connect" | "ble.subscribe" | "ble.write" | "ble.close" =>
    return Json.mkObj [("ok", false), ("error", Json.str "unsupported")]
  | "ble.read" => return Json.mkObj [("error", Json.str "disconnected")]
  | "bgtask.schedule" | "bgtask.complete" => return Json.mkObj [("ok", true)]
  | "bgtask.refreshStatus" => return Json.mkObj [("status", Json.str "available")]
  | "cloudkit.account" => return Json.mkObj [("status", Json.str "noAccount"), ("user", Json.null)]
  | n =>
    if n.startsWith "cloudkit." then
      return Json.mkObj [("error", Json.str "notAuthenticated"), ("code", toJson (9 : Int)), ("detail", Json.str "the headless driver has no iCloud account")]
    return Json.mkObj [("error", Json.str "unsupported")]

def answer (sh : Shell) (name : String) (args : Json) : IO Json := do
  match ← sh.override name args with
  | some j => return j
  | none => sh.defaultAnswer name args

end Shell

/-! ## Elements in the tree -/

/-- A node as the journey can name it: its identifier, the node without its `identified`/`decorated` wrappers,
and its path in the tree (the wrappers share it: `Wire.at?`). -/
structure Elem where
  id : Option String
  node : Wire
  path : List Nat
  deriving Inhabited

partial def unwrap : Wire → Option String × Wire
  | .identified i w => let (j, inner) := unwrap w; (j.getD i |> some, inner)
  | .decorated _ w => unwrap w
  | w => (none, w)

def Elem.at (w : Wire) (path : List Nat) : Elem :=
  let (id, node) := unwrap w
  { id, node, path }

def isOverlay : Wire → Bool
  | .sheet .. | .alert .. => true
  | _ => false

/-- Every node under `e` (not `e`), outermost first, not looking into a sheet or alert (an overlay is found by
`overlays`, and what it covers is not seen). -/
partial def Elem.descendants (e : Elem) : List Elem :=
  go e.node e.path
where
  go (w : Wire) (p : List Nat) : List Elem :=
    w.children.zipIdx.flatMap fun (c, i) =>
      let child := Elem.at c (p ++ [i])
      child :: (if isOverlay child.node then [] else go child.node (p ++ [i]))

/-- The sheets and alerts presented from `e`: its first-level overlays (an overlay inside an overlay belongs to that one). -/
def Elem.overlays (e : Elem) : List Elem := e.descendants.filter (isOverlay ·.node)

inductive TopKind where
  | base
  | sheet
  | alert
  deriving BEq, Repr, Inhabited

/-- What a person sees: the tab bar when nothing covers it, and the topmost presentation. -/
structure Scene where
  tabs : Option Elem
  top : Elem
  kind : TopKind
  deriving Inhabited

partial def scene (root : Wire) : Scene :=
  let (tabs, base) := selected (Elem.at root []) none
  descend base (if tabs.isSome then tabs else none) .base
where
  /-- Through the tab bar to the selected tab's content. -/
  selected (e : Elem) (tabs : Option Elem) : Option Elem × Elem :=
    match e.node with
    | .tabs _ _ sel cs =>
      match cs[sel]? with
      | some c => selected (Elem.at c (e.path ++ [sel])) (some e)
      | none => (some e, e)
    | _ => (tabs, e)
  /-- Into the innermost presentation: an alert covers what presents it; a sheet presents the next. -/
  descend (e : Elem) (tabs : Option Elem) (kind : TopKind) : Scene :=
    let os := e.overlays
    match os.find? (fun o => match o.node with | .alert .. => true | _ => false) with
    | some a => { tabs := none, top := a, kind := .alert }
    | none =>
      match os.getLast? with
      | some s => descend s none .sheet
      | none => { tabs, top := e, kind }

/-- The elements on screen: the top presentation and everything in it. -/
def Scene.elements (sc : Scene) : List Elem := sc.top :: sc.top.descendants

/-- The strings a node shows of its own (a `labeled` row's label then its value; an input's value, else its
placeholder; a picker's chosen option). -/
def own : Wire → List String
  | .text s _ => [s]
  | .button l _ _ => [l]
  | .labeled l v => [l, v]
  | .toggle l _ => [l]
  | .stepper l _ _ _ d => [l] ++ (if d.isEmpty then [] else [d])
  | .section h f _ => [h, f].filter (· != "")
  | .progress l => [l]
  | .empty t _ m _ => [t, m]
  | .disclosure t _ _ => [t]
  | .input _ l p v _ => [l, if v.isEmpty then p else v].filter (· != "")
  | .field p v _ => [if v.isEmpty then p else v]
  | .picker l os sel => [os[sel]?.getD l]
  | .share l _ _ => [l]
  | .link l _ => [l]
  | .alert t m _ _ => [t, m]
  | _ => []

def isControl : Wire → Bool
  | .button .. | .input .. | .field .. | .toggle .. | .picker .. | .stepper .. | .share .. | .link .. | .disclosure .. => true
  | _ => false

/-- The control the identifier lands on (`LNIdentify`: a node's control, else its label): the element itself when
it is one, else the first control in it (a row of a button and a checkmark is tapped by its button). -/
def Elem.control? (e : Elem) : Option Elem :=
  if isControl e.node then some e else e.descendants.find? (isControl ·.node)

/-- The text XCTest reads for the element: the label of its control, else its last label (a `labeled` row's value),
else, for a container of other nodes, their texts joined. -/
def Elem.text (e : Elem) : String :=
  match e.control? with
  | some c => (own c.node).head?.getD ""
  | none =>
    match (own e.node).getLast? with
    | some s => s
    | none =>
      let inner := e.descendants.filter (fun d => !(isControl d.node)) |>.flatMap (own ·.node)
      " ".intercalate inner

/-! ## Finding -/

/-- A `find` as the host sends it (`Journey.Find.toJson`). -/
def Find.ofJson? (j : Json) : Option Find := do
  let s (k : String) : Option String := (j.getObjValAs? String k).toOption
  let inner : Option Find :=
    if let some i := s "id" then some (.id i)
    else if let some t := s "tab" then some (.tab t)
    else if let some b := s "alert" then some (.alert b)
    else if let some l := s "button" then some (.button l)
    else if let some t := s "nav" then some (.nav t)
    else if (j.getObjValAs? Bool "back").toOption == some true then some .back
    else if let some p := s "text" then some (.text p)
    else none
  let f ← inner
  match s "in" with
  | some parent => some (.inside parent f)
  | none => some f

/-- What a step acts on. -/
inductive Target where
  | elem (e : Elem)
  | tab (bar : Elem) (index : Nat)
  | stepperHalf (e : Elem) (up : Bool)
  | pickerOption (picker : Elem) (index : Nat)
  /-- the screen's back button -/
  | back (screen : Elem)

def Target.elem? : Target → Elem
  | .elem e => e
  | .tab b _ => b
  | .stepperHalf e _ => e
  | .pickerOption p _ => p
  | .back s => s

private def buttonLabelled (l : String) (e : Elem) : Bool :=
  match e.node with
  | .button label _ _ => label == l
  | _ => false

/-- The element `f` names in the scene, if it is there now. `openPicker`: the picker whose menu the last tap
opened, whose options are `button`s until the next tap. -/
partial def find (sc : Scene) (openPicker : Option (List Nat)) (f : Find) : Except String (Option Target) := do
  let elems := sc.elements
  match f with
  | .id i =>
    if let some e := elems.find? (·.id == some i) then return some (.elem e)
    for (suffix, up) in [("-Increment", true), ("-Decrement", false)] do
      if i.endsWith suffix then
        let base := i.dropEnd suffix.length
        if let some e := elems.find? (fun e => e.id == some base && match e.node with | .stepper .. => true | _ => false) then
          return some (.stepperHalf e up)
    return none
  | .tab t =>
    let some bar := sc.tabs | return none
    match bar.node with
    | .tabs labels _ _ _ =>
      match labels.idxOf? t with
      | some i => return some (.tab bar i)
      | none => return none
    | _ => return none
  | .alert b =>
    unless sc.kind == .alert do return none
    return (elems.find? (buttonLabelled b)).map .elem
  | .button l =>
    if let some p := openPicker then
      if let some picker := elems.find? (·.path == p) then
        if let .picker _ options _ := picker.node then
          if let some i := options.idxOf? l then return some (.pickerOption picker i)
    return (elems.find? (buttonLabelled l)).map .elem
  | .nav t =>
    return (elems.find? fun e => match e.node with
      | .screen title .. => title == t
      | .sheet title .. => title == t
      | _ => false).map .elem
  | .back =>
    -- the screen's own back, else the first button of a leading or cancel toolbar (a sheet's Close)
    if let some s := elems.find? (fun e => match e.node with | .screen _ true .. => true | _ => false) then
      return some (.back s)
    for e in elems do
      if let .toolbar _ p := e.node then
        if p == .cancel || p == .leading then
          if let some b := e.descendants.find? (fun d => match d.node with | .button .. => true | _ => false) then
            return some (.elem b)
    return none
  | .text pattern =>
    let re ← Regex.parse pattern |>.mapError (s!"the pattern {pattern}: {·}")
    return (elems.find? fun e => (own e.node).any (Regex.search re ·)).map .elem
  | .inside parent child =>
    let some p := elems.find? (·.id == some parent) | return none
    let inside := p.descendants
    match child with
    | .id i => return (inside.find? (·.id == some i)).map .elem
    | .button l => return (inside.find? (buttonLabelled l)).map .elem
    | other => throw s!"a find inside {parent} must be an id or a button, not {other.describe}"

/-- Whether the target would take a touch now. -/
def Target.enabled : Target → Bool
  | .elem e => match (e.control?.getD e).node with
    | .button _ _ en => en
    | _ => true
  | .stepperHalf e up => match e.node with
    | .stepper _ v lo hi _ => if up then v < hi else v > lo
    | _ => false
  | _ => true

/-- The event a tap on the target sends, at which path; none when the node advertises nothing for a touch. -/
def Target.tapEvent : Target → Option (List Nat × Event)
  | .elem e =>
    let c := e.control?.getD e
    match c.node with
    | .button _ _ en => if en then some (c.path, .click) else none
    | .toggle _ on => some (c.path, .toggle !on)
    | .disclosure _ expanded _ => some (c.path, .toggle !expanded)
    | _ => none
  | .tab bar i => some (bar.path, .select i)
  | .pickerOption p i => some (p.path, .select i)
  | .stepperHalf e up => match e.node with
    | .stepper _ v lo hi _ => some (e.path, .select (if up then min hi (v + 1) else max lo (v - 1)))
    | _ => none
  | .back s => some (s.path, .dismiss)

/-- The input a `type` writes into: the element, or the first input in it. -/
def Target.inputPath : Target → Option (List Nat)
  | .elem e =>
    let isInput (w : Wire) := match w with | .input .. | .field .. => true | _ => false
    if isInput e.node then some e.path else (e.descendants.find? (isInput ·.node)).map (·.path)
  | _ => none

def eventJson : Event → Json
  | .click => Json.mkObj [("k", Json.str "click")]
  | .input s => Json.mkObj [("k", Json.str "input"), ("value", Json.str s)]
  | .submit => Json.mkObj [("k", Json.str "submit")]
  | .toggle b => Json.mkObj [("k", Json.str "toggle"), ("value", Json.bool b)]
  | .select n => Json.mkObj [("k", Json.str "select"), ("value", toJson n)]
  | .dismiss => Json.mkObj [("k", Json.str "dismiss")]

/-! ## The running app -/

structure State where
  runtime : Runtime
  /-- Every call into the runtime holds it: the shell's "main thread". -/
  lock : Std.Mutex Unit
  shell : Shell
  openPicker : IO.Ref (Option (List Nat))
  quiet : Bool

def appearTimeout : Float := 20
def enabledTimeout : Float := 15

namespace State

def say (st : State) (line : String) : IO Unit := do
  unless st.quiet do
    let out ← IO.getStdout
    out.putStrLn s!"  [app] {line}"
    out.flush

/-- The capability requests a reply carries, answered by the fake shell. -/
def answerCaps (st : State) (reply : String) : IO Unit := do
  let .ok j := Json.parse reply | return
  let caps := ((j.getObjVal? "caps").toOption.bind (·.getArr?.toOption)).getD #[]
  for c in caps do
    let id := (c.getObjValAs? Nat "id").toOption.getD 0
    let name := (c.getObjValAs? String "name").toOption.getD ""
    let args := (c.getObjVal? "args").toOption.getD Json.null
    let result ← try st.shell.answer name args catch e => pure (Json.mkObj [("error", Json.str (toString e))])
    st.runtime.capResult (Json.mkObj [("id", toJson id), ("result", result)]).compress

def view (st : State) : IO Wire := do
  let (_, w) ← st.lock.atomically fun _ => st.runtime.current
  return w

def scene (st : State) : IO Scene := do return _root_.LeanNative.Journey.Wire.scene (← st.view)

/-- Applies the host answers queued so far (the shell's `drain`) and answers the capabilities asked. -/
def drain (st : State) : IO Unit := do
  let reply ← st.lock.atomically fun _ => st.runtime.drain
  st.answerCaps reply

/-- Runs while the app does: whenever the runtime has an answer or a request queued, drains it. -/
partial def pump (st : State) : IO Unit := do
  repeat
    st.runtime.wait
    st.drain

def system (st : State) (event : Json) : IO Unit := do
  let reply ← st.lock.atomically fun _ => st.runtime.system event.compress
  st.answerCaps reply

def scenePhase (st : State) (phase : String) : IO Unit := st.system (Json.mkObj [("scene", Json.str phase)])

/-- One event at a path, as the shell sends a touch; the dispatcher's refusal (stale, no handler) is the reason. -/
def send (st : State) (path : List Nat) (event : Event) : IO (Option String) := do
  let reply ← st.lock.atomically fun _ => do
    let (seq, _) ← st.runtime.current
    st.runtime.event (Json.mkObj [("seq", toJson seq), ("path", toJson path), ("event", eventJson event)]).compress
  st.answerCaps reply
  match Json.parse reply with
  | .ok j => return (j.getObjValAs? String "error").toOption.map fun e => s!"the app refused the event: {e}"
  | .error e => return some s!"the app's reply is not JSON: {e}"

/-- Polls `check` every 50 ms until it answers, or `timeout` seconds pass. -/
def poll (timeout : Float) (check : IO (Option α)) : IO (Option α) := do
  let deadline := (← IO.monoMsNow) + (timeout * 1000).toUInt64.toNat
  repeat
    if let some a ← check then return some a
    if (← IO.monoMsNow) ≥ deadline then return ← check
    IO.sleep 50
  return none

/-- The target `f` names, once it appears, with the scene it was found in. -/
def locate (st : State) (f : Find) (timeout : Float) : IO (Except String (Option (Target × Scene))) := do
  let found : Option (Except String (Target × Scene)) ← poll timeout do
    let sc ← st.scene
    match find sc (← st.openPicker.get) f with
    | .error e => return some (Except.error e)
    | .ok (some t) => return some (Except.ok (t, sc))
    | .ok none => return none
  return match found with
    | some (.error e) => .error e
    | some (.ok r) => .ok (some r)
    | none => .ok none

/-- The target, appeared and enabled, or why not (the drivers' wording). -/
def ready (st : State) (f : Find) : IO (Except String Target) := do
  match ← st.locate f appearTimeout with
  | .error e => return .error e
  | .ok none => return .error s!"{f.describe} does not appear within {appearTimeout} s"
  | .ok (some _) =>
    let enabled ← poll enabledTimeout do
      let sc ← st.scene
      match find sc (← st.openPicker.get) f with
      | .ok (some t) => return if t.enabled then some t else none
      | _ => return none
    match enabled with
    | some t => return .ok t
    | none => return .error s!"{f.describe} stays disabled for {enabledTimeout} s"

def ok (more : List (String × Json) := []) : Json := Json.mkObj (("ok", Json.bool true) :: more)
def refuse (why : String) : Json := Json.mkObj [("ok", Json.bool false), ("error", Json.str why)]

/-- A tap's effect on the target: the event it advertises, or a picker's menu opened. -/
def activate (st : State) (t : Target) (name : String) : IO (Option String) := do
  st.openPicker.set none
  match t with
  | .elem e =>
    let c := e.control?.getD e
    if let .picker .. := c.node then
      st.openPicker.set (some c.path)
      return none
  | _ => pure ()
  match t.tapEvent with
  | some (path, event) => st.send path event
  | none => return some s!"{name} takes no touch: it advertises no event (a label, a row without an action)"

/-- The answer to one of the driver's commands; `ended` for `end`. -/
def answer (st : State) (command : Json) : IO (Json × Bool) := do
  let op := (command.getObjValAs? String "op").toOption.getD ""
  let timeout := (command.getObjValAs? Float "timeout").toOption.getD appearTimeout
  let fieldStr (k : String) : Option String := (command.getObjValAs? String k).toOption
  match op with
  | "end" => return (ok, true)
  -- the host prints the journey's log and failures itself
  | "log" | "fail" => return (ok, false)
  | "home" =>
    st.scenePhase "inactive"
    st.scenePhase "background"
    return (ok, false)
  | "activate" =>
    st.scenePhase "inactive"
    st.scenePhase "active"
    return (ok, false)
  | "shot" =>
    let name := (fieldStr "name").getD "shot"
    if let some dir := fieldStr "directory" then
      let sc ← st.scene
      IO.FS.createDirAll dir
      IO.FS.writeFile (System.FilePath.mk dir / s!"{name}.wire.json") ((sc.top.node.toJson).pretty ++ "\n")
    return (ok, false)
  | _ => pure ()
  let some f := (command.getObjVal? "find").toOption.bind Find.ofJson? | return (refuse s!"{op}: no find", false)
  match op with
  | "exists" =>
    match ← st.locate f (max timeout 0) with
    | .error e => return (refuse e, false)
    | .ok r => return (ok [("exists", Json.bool r.isSome)], false)
  | "gone" =>
    let gone ← poll (max timeout 0) do
      let sc ← st.scene
      match find sc (← st.openPicker.get) f with
      | .ok none => return some true
      | _ => return none
    return (ok [("gone", Json.bool gone.isSome)], false)
  | "text" =>
    match ← st.locate f (max timeout 0) with
    | .error e => return (refuse e, false)
    | .ok none => return (refuse s!"{f.describe} does not appear within {timeout} s", false)
    | .ok (some (t, _)) =>
      let text := match t with
        | .tab bar i => match bar.node with | .tabs labels .. => labels[i]?.getD "" | _ => ""
        | .pickerOption p i => match p.node with | .picker _ os _ => os[i]?.getD "" | _ => ""
        | other => other.elem?.text
      return (ok [("text", Json.str text)], false)
  | "state" =>
    let sc ← st.scene
    match find sc (← st.openPicker.get) f with
    | .error e => return (refuse e, false)
    | .ok none => return (ok [("exists", false), ("enabled", false), ("hittable", false)], false)
    | .ok (some t) => return (ok [("exists", true), ("enabled", Json.bool t.enabled), ("hittable", true)], false)
  | "scroll" =>
    match ← st.locate f 2 with
    | .error e => return (refuse e, false)
    | .ok r => return (ok [("hittable", Json.bool r.isSome)], false)
  | "describe" =>
    let sc ← st.scene
    match find sc (← st.openPicker.get) f with
    | .error e => return (refuse e, false)
    | .ok none => return (ok [("exists", false)], false)
    | .ok (some t) =>
      let e := t.elem?
      return (ok [("exists", true), ("path", toJson e.path), ("text", Json.str e.text), ("node", e.node.toJson)], false)
  | "tap" | "press" | "type" =>
    match ← st.ready f with
    | .error why => return (refuse why, false)
    | .ok t =>
      let name := f.describe
      if op == "type" then
        let some path := t.inputPath | return (refuse s!"{name} is not a text input", false)
        match ← st.send path (.input ((fieldStr "text").getD "")) with
        | some why => return (refuse why, false)
        | none => return (ok, false)
      let times := (command.getObjValAs? Nat "times").toOption.getD 1 |> max 1
      -- held down, a stepper's half repeats to its end
      let times := if op == "press" then (match t with | .stepperHalf .. => 100000 | _ => 1) else times
      let mut done := 0
      let mut current := t
      while done < times do
        if done > 0 then
          -- found again: a new tree after each event
          let sc ← st.scene
          match find sc (← st.openPicker.get) f with
          | .ok (some again) => current := again
          | _ => break
        unless current.enabled do break
        if let some why ← st.activate current name then
          if done == 0 then return (refuse why, false) else break
        done := done + 1
      return (ok, false)
  | other => return (refuse s!"unknown command {other}", false)

end State

/-! ## The child process -/

private def newline? (b : ByteArray) : Option Nat := Id.run do
  for i in [0:b.size] do
    if b.get! i == 10 then return some i
  return none

private partial def readLine (socket : TCP.Socket.Client) (pending : IO.Ref ByteArray) : IO (Option String) := do
  let buf ← pending.get
  match newline? buf with
  | some i =>
    pending.set (buf.extract (i + 1) buf.size)
    return String.fromUTF8? (buf.extract 0 i)
  | none =>
    match ← (socket.recv? 65536).block with
    | some more => pending.set (buf ++ more); readLine socket pending
    | none => return none

private partial def connect (port : UInt16) (attempts : Nat) : IO TCP.Socket.Client := do
  let socket ← TCP.Socket.Client.mk
  try
    (socket.connect (.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port })).block
    return socket
  catch e =>
    if attempts == 0 then throw e
    IO.sleep 100
    connect port (attempts - 1)

/-- Runs the app headless as the journey driver, connected to the host on `port`, until the journey ends it. The
app's files go under `LEANNATIVE_WIRE_DIR` (the current directory's `wire/` otherwise). -/
def serve [ToJson Cmd] (app : Native.App Model Msg Cmd Host) (port : UInt16)
    (override : String → Json → IO (Option Json) := fun _ _ => pure none) : IO Unit := do
  let dir ← match ← IO.getEnv "LEANNATIVE_WIRE_DIR" with
    | some d => pure (System.FilePath.mk d)
    | none => do let cwd ← IO.currentDir; pure (cwd / "wire")
  let shell ← Shell.new dir override
  let st : State := { runtime := ← Native.runtime app, lock := ← Std.Mutex.new (), shell,
                      openPicker := ← IO.mkRef none, quiet := (← IO.getEnv "LEANNATIVE_WIRE_QUIET") == some "1" }
  -- as the shell starts the app: the first view, then the scene phases a launch goes through
  let first ← st.lock.atomically fun _ => st.runtime.start
  st.answerCaps first
  st.scenePhase "inactive"
  st.scenePhase "active"
  let _ ← IO.asTask (prio := .dedicated) st.pump
  let socket ← connect port 50
  let pending ← IO.mkRef ByteArray.empty
  let mut ended := false
  while !ended do
    let some line ← readLine socket pending | break
    let answer : Json × Bool ← match Json.parse line with
      | .error e => pure (State.refuse s!"not JSON: {e}", false)
      | .ok command =>
        try st.answer command catch e => pure (State.refuse s!"the driver failed: {e}", false)
    ended := answer.2
    (socket.send (answer.1.compress ++ "\n").toUTF8).block
  -- the app's own tasks (sync loops, timers) must not hold the process open
  IO.Process.exit 0

/-- The app, for `Journey.main`'s `wire`: `Journey.main journeys args (wire := some (Wire.app myApp))`. -/
def app [ToJson Cmd] (a : Native.App Model Msg Cmd Host)
    (override : String → Json → IO (Option Json) := fun _ _ => pure none) : WireApp :=
  { serve := fun port => serve a port override }

end LeanNative.Journey.Wire
