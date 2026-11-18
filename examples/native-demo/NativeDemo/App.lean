import Std.Async.TCP
import Std.Sync.Mutex
import LeanNative.Native
import LeanNative.Native.BackgroundRun
import LeanNative.Native.EffectScope
import LeanNative.Native.Client.Auth
import LeanNative.Native.Client.Keychain
import LeanNative.Native.Client.Http
import LeanNative.Native.Client.HttpRequest
import LeanNative.Native.Client.CloudKit
import LeanNative.Native.Client.Push
import LeanNative.Native.Client.Bluetooth

/-! # A native-mode demo: the pieces Winnow needs, in one screen

* `update`/`view`/`cmds` as in any LeanNative app;
* a command run by a Lean task that answers every second (`tick`);
* a command that asks the shell for an iOS capability (`auth`: Face ID or the passcode);
* a command that talks TCP through Lean's own libuv sockets (an echo server and client in-process);
* a Probes tab that asks the shell for capabilities (background tasks, CloudKit, iCloud Keychain, HTTP
  through a SOCKS5 proxy at 127.0.0.1:1080) and logs their answers and the system events;
* a background task iOS launches runs as a `BackgroundRun` (`LeanNative.Native.BackgroundRun`): a short
  job that stops when expired, answered with `bgtask.complete` when it is over;
* the selftest (`NATIVEDEMO_SELFTEST=1` at launch) runs two `BackgroundRun`s, a scoped task an
  invalidation drains, and the typed clients (`LeanNative.Native.Client.*`) against the real shell, `http.*`
  against two servers of its own on 127.0.0.1 that redirect and send more than was asked for; its lines
  are printed and shown on the Demo tab (`selftest-<n>`), so UI tests read them on iOS and Mac Catalyst alike;
* its `keychain-user-presence` part stores an item behind the person's presence and upgrades another in
  place, and shows that neither is read without an authentication; with `NATIVEDEMO_KEYCHAIN_PROMPT=1` as
  well it asks the person once (`auth` with `keep`) and reads both under that one answer. Its last line
  says which of those a device showed;
* Face ID runs in an `EffectScope` the app's going to the background ends: an answer that comes back
  after that is dropped; going to the background and coming back from it are logged; each answer, a
  dropped one too, and the scope's end are printed to stdout (`auth: …`, `scene: …`), and so are the
  background tasks iOS launches and expires (`bgtask …`), for hand checks that keep the output;
* with `NATIVEDEMO_AUTH_AFTER=<seconds>` at launch, the app asks for Face ID that long after launching, as
  its Face ID button does, for hand checks where nobody clicks;
* with `NATIVEDEMO_BLE_SERVICE=<a service UUID>` at launch, the Probes tab has a Bluetooth section: the
  Bluetooth state, and a connection to the first peripheral offering that service (its id and name logged),
  closed at once. Nothing else is said to the peripheral; without the variable the app never touches
  Bluetooth, so no run that does not set it is asked for the permission. -/

namespace NativeDemo
open LeanNative LeanNative.Native Lean

structure Model where
  count : Nat
  ticks : Nat
  ticking : Bool
  log : List String
  tab : Nat := 0
  fee : Nat := 1
  copies : Nat := 1
  /-- what the swipe row's last action was -/
  swiped : String := "Nothing yet"
  /-- What the clipboard held when it was last read (the selectable text's demo). -/
  pasted : String := ""
  /-- the columns (`Html.split`) in place of the tabs, and which of them a narrow window shows -/
  columns : Option Nat := none
  /-- the box chosen in the sidebar, and the item chosen in its list -/
  box : Nat := 0
  item : Nat := 0
  details : Bool := false
  secret : String := ""
  sheet : Bool := false
  /-- the screen the sheet's button opens, pushed over the Widgets tab's -/
  pushed : Bool := false
  alert : Bool := false
  name : String := ""
  /-- the selftest's lines, newest first -/
  selftest : List String := []
  /-- `NATIVEDEMO_BLE_SERVICE`, when set at launch -/
  bleService : Option String := none
  /-- in the background since the last time the app was active -/
  away : Bool := false
  deriving Inhabited

inductive Host where
  | tick
  | authed (ok : Bool) (detail : String)
  | echoed (reply : String)
  | probed (label : String) (result : Json)
  | system (event : Json)
  /-- iOS launched (`expired := false`) or expired a background task, with the shell's tag for that launch -/
  | bgtask (expired : Bool) (id kind : String) (tag : Option Nat)
  /-- a push notice received, about to be answered by the shell, or tapped (`Client.Push.event?`) -/
  | push (event : Json)
  /-- a background run ended -/
  | ran (id : String) (outcome : String)
  /-- the app went to the background -/
  | background
  /-- the app is active (after a launch, a system sheet, or the background) -/
  | foreground
  /-- a scoped answer came back stale and was not delivered -/
  | dropped (what : String)
  /-- one line of the selftest -/
  | checked (line : String)
  /-- the Bluetooth service to connect to (`NATIVEDEMO_BLE_SERVICE`) -/
  | bleService (uuid : String)
  /-- one answer of the Bluetooth probes -/
  | bleSaid (line : String)
  /-- `NATIVEDEMO_AUTH_AFTER` seconds have passed since launch: ask as the Face ID button does -/
  | authCue
  /-- what the clipboard holds (`clipboard.get`), "" when it holds no text -/
  | pasted (text : String)

inductive Msg where
  | inc
  | startTicks
  | authenticate
  | echo
  | tab (i : Nat)
  | fee (i : Nat)
  | copies (n : Nat)
  | swiped (what : String)
  | readClipboard
  | columns (shown : Option Nat)
  | box (i : Nat)
  | item (i : Nat)
  | details (b : Bool)
  | secret (s : String)
  | openSheet
  | closeSheet
  | openPushed
  | closePushed
  | openAlert
  | closeAlert
  | probe (i : Nat)
  | name (s : String)
  | bleState
  | bleConnect
  | host (h : Host)

inductive Cmd where
  | ticker
  | auth
  /-- reads the clipboard (`clipboard.get`): what the selectable text's Copy put there -/
  | readClipboard
  | echo (text : String)
  | probe (label name : String) (args : Json)
  /-- a push event: printed, and a notice whose payload says how (`"answer"`) is answered so -/
  | pushed (event : Json)
  /-- at launch: with `NATIVEDEMO_SELFTEST` set, the TCP echo, two background runs and every probe,
  answers printed -/
  | selftest
  /-- at launch: reads `NATIVEDEMO_BLE_SERVICE` -/
  | bleSetup
  /-- at launch: with `NATIVEDEMO_AUTH_AFTER=<seconds>`, asks for Face ID / Touch ID that long after
  launch, for hand checks where nobody can click (the Face ID button's command) -/
  | authSetup
  | bleState
  /-- connects to the first peripheral offering the service, logs it and closes the connection -/
  | bleConnect (service : String)
  | runBackground (id kind : String) (tag : Option Nat)
  /-- ends the session scope (`EffectScope.invalidate`) -/
  | endSession
  | expireBackground (id : String) (tag : Option Nat)
  deriving ToJson

/-- The Probes tab: a label, a capability and its arguments. The background task identifiers are the
demo's Info.plist `BGTaskSchedulerPermittedIdentifiers`. -/
def probes : List (String × String × Json) :=
  let refresh := "art.fralex.leannative.nativedemo.refresh"
  let processing := "art.fralex.leannative.nativedemo.processing"
  let probeService := "art.fralex.leannative.nativedemo.probe"
  [ ("Refresh status", "bgtask.refreshStatus", Json.mkObj []),
    ("Schedule refresh", "bgtask.schedule", Json.mkObj [("id", refresh), ("after", (900 : Nat))]),
    ("Schedule processing", "bgtask.schedule",
      Json.mkObj [("id", processing), ("kind", "processing"), ("requiresNetwork", true)]),
    ("Schedule unlisted id", "bgtask.schedule", Json.mkObj [("id", "not.in.info.plist")]),
    ("Complete (none pending)", "bgtask.complete", Json.mkObj [("id", refresh), ("success", true)]),
    -- continued processing (iOS 26): the launch arrives as a `bgtask` event of kind `continued`, and the demo's
    -- background run answers it; `unavailable` on an older iOS and on the Mac
    ("Continue work", "bgtask.continue",
      Json.mkObj [("id", "art.fralex.leannative.nativedemo.work.demo"), ("title", "Native demo"), ("subtitle", "A piece of work that outlives the screen")]),
    ("Continue unlisted id", "bgtask.continue", Json.mkObj [("id", "not.in.info.plist.work"), ("title", "No")]),
    ("Progress (none pending)", "bgtask.progress",
      Json.mkObj [("id", "art.fralex.leannative.nativedemo.work.demo"), ("completed", (1 : Nat)), ("total", (2 : Nat))]),
    ("CloudKit account", "cloudkit.account", Json.mkObj []),
    ("CloudKit query", "cloudkit.query", Json.mkObj [("type", "WalletBackup")]),
    ("Keychain sync set", "keychain.set",
      Json.mkObj [("key", "probe"), ("service", probeService), ("hex", "00ff10"), ("synchronizable", true)]),
    ("Keychain sync get", "keychain.get",
      Json.mkObj [("key", "probe"), ("service", probeService), ("hex", true), ("synchronizable", true)]),
    ("Keychain local get", "keychain.get",
      Json.mkObj [("key", "probe"), ("service", probeService), ("hex", true)]),
    ("Keychain sync delete", "keychain.delete",
      Json.mkObj [("key", "probe"), ("service", probeService), ("synchronizable", true)]),
    ("HTTP via SOCKS", "http.get",
      Json.mkObj [("url", "http://socksprobe/hello"), ("maxBytes", (10000 : Nat)),
                  ("socks", Json.mkObj [("host", "127.0.0.1"), ("port", (1080 : Nat))])]),
    ("HTTP bad proxy", "http.get",
      Json.mkObj [("url", "https://example.com/"), ("socks", Json.mkObj [("host", ""), ("port", (0 : Nat))])]),
    -- Apple's push, last (the UI tests scroll to the last probe by its number). The demo has no entitlement,
    -- so the token is refused before Apple is asked. A notice that arrives is logged below (`push`,
    -- `pushExpired`, `pushPresented`, `pushOpened`); the first one's tag is 1, which the third row answers
    ("Push register", "push.register", Json.mkObj []),
    ("Push permission", "push.permission", Json.mkObj []),
    ("Push complete (the first notice)", "push.complete", Json.mkObj [("tag", (1 : Nat)), ("result", "newData")]) ]

def note (m : Model) (s : String) : Model := { m with log := (s :: m.log).take 12 }

def update : Msg → Model → Model
  | .inc, m => { m with count := m.count + 1 }
  | .startTicks, m => { m with ticking := true }
  | .authenticate, m => note m "asking for Face ID or the passcode…"
  | .echo, m => note m "sending ping over TCP…"
  | .tab i, m => { m with tab := i }
  | .fee i, m => { m with fee := i }
  | .copies n, m => { m with copies := n }
  | .swiped what, m => { m with swiped := what }
  | .readClipboard, m => m
  | .host (.pasted text), m => { m with pasted := text }
  | .columns shown, m => { m with columns := shown }
  -- a choice in one column shows the next (which is all a narrow window has room for)
  | .box i, m => { m with box := i, item := 0, columns := some 1 }
  | .item i, m => { m with item := i, columns := some 2 }
  | .details b, m => { m with details := b }
  | .secret s, m => { m with secret := s }
  | .openSheet, m => { m with sheet := true }
  | .closeSheet, m => { m with sheet := false }
  -- the sheet's button: the sheet goes and a screen is pushed, in one view
  | .openPushed, m => { m with sheet := false, pushed := true }
  | .closePushed, m => { m with pushed := false }
  | .openAlert, m => { m with alert := true }
  | .closeAlert, m => { m with alert := false }
  | .name s, m => { m with name := s }
  | .probe i, m => note m s!"asking: {(probes[i]?.map (·.1)).getD "?"}…"
  | .host .tick, m => { m with ticks := m.ticks + 1 }
  | .host (.authed ok d), m => note m (if ok then s!"authenticated {d}" else s!"not authenticated: {d}")
  | .host (.echoed r), m => note m s!"TCP echo: {r}"
  | .host (.probed l r), m => note m s!"{l}: {r.compress}"
  | .host (.system e), m => note m s!"system: {e.compress}"
  | .host (.bgtask expired id kind _), m => note m s!"bgtask {if expired then "expired" else "launched"}: {id} ({kind})"
  | .host (.push e), m => note m s!"push: {e.compress}"
  | .host (.ran id o), m => note m s!"background run {id}: {o}"
  | .host .background, m => { note m "went to the background" with away := true }
  | .host .foreground, m => if m.away then { note m "back in the foreground" with away := false } else m
  | .host (.dropped what), m => note m s!"dropped a stale answer: {what}"
  | .host (.checked line), m => { m with selftest := line :: m.selftest }
  | .bleState, m => note m "asking: BLE state…"
  | .bleConnect, m => note m "asking: BLE connect…"
  | .host (.bleService s), m => { m with bleService := some s }
  | .host (.bleSaid line), m => note m line
  | .host .authCue, m => note m "asking for Face ID or the passcode… (NATIVEDEMO_AUTH_AFTER)"

def cmds : Msg → Model → List Cmd
  | .startTicks, m => if m.ticking then [] else [.ticker]
  | .authenticate, _ => [.auth]
  | .readClipboard, _ => [.readClipboard]
  | .echo, m => [.echo s!"ping {m.count}"]
  -- its answer is a second view within milliseconds, while the sheet is still on its way out
  | .openPushed, _ => [.echo "pushed"]
  | .probe i, _ => match probes[i]? with
    | some (l, n, a) => [.probe l n a]
    | none => []
  | .bleState, _ => [.bleState]
  | .bleConnect, m => match m.bleService with
    | some s => [.bleConnect s]
    | none => []
  | .host (.bgtask false id kind tag), _ => [.runBackground id kind tag]
  | .host (.push e), _ => [.pushed e]
  | .host (.bgtask true id _ tag), _ => [.expireBackground id tag]
  | .host .background, _ => [.endSession]
  | .host .authCue, _ => [.auth]
  | _, _ => []

def demoView (m : Model) : Html Msg :=
  .col ([ .text "Native mode" .title
        , .text "This screen is Lean compiled to C, running inside the iOS app." .caption
        , .row [.identified "count" (.text s!"Count: {m.count}" .body), .spacer, Html.key "cmd+k" (.identified "inc" (.button "+1" .primary (some .inc)))]
        , .row [.text s!"Ticks from a Lean task: {m.ticks}" .body, .spacer,
                .identified "startTicks" (.button "Start" .plain (if m.ticking then none else some .startTicks))]
        -- keys (`Decor.key`): cmd-K is +1's click, and cmd-F, the system's Find, puts the cursor in the field
        -- a text that can be selected (`Decor.selectable`): the system's menu on it copies, and a key with no
        -- command (↓ is +1 too) is still the app's while the text has the keyboard, nothing being typed in it
        , Html.selectable (.identified "words" (.text "Select these words." .body))
        , .row [ .identified "pasted" (Html.tone .secondary (.text (if m.pasted.isEmpty then "Nothing copied yet" else s!"Copied: {m.pasted}") .caption)), .spacer,
                 .identified "readClipboard" (.button "Read clipboard" .plain (some .readClipboard)),
                 Html.key "down" (.identified "incDown" (.button "+1 (↓)" .plain (some .inc))) ]
        , Html.key "cmd+f" (.identified "name" (.input .plain "Name" "Who is asking" m.name Msg.name none))
        , .identified "greeting" (.text (if m.name.isEmpty then "Nobody yet" else s!"Hello, {m.name}") .body)
        , .row [.identified "faceID" (.button "Face ID" .plain (some .authenticate)), .button "TCP echo" .plain (some .echo)]
        , .identified "openColumns" (.button "Columns" .plain (some (.columns (some 0)))) ]
        -- one element a line (an accessibility label has no line breaks): selftest-0, selftest-1, …
        ++ m.selftest.reverse.zipIdx.map (fun (l, i) => .identified s!"selftest-{i}" (.text l .caption))
        ++ [.divider] ++ m.log.map (fun s => .text s .caption))

def widgets (m : Model) : Html Msg :=
  .screen "Widgets" none
    [ .toolbar [.button "Alert" .plain (some .openAlert)]
    , .list
      [ .section "Values" "Every value below lives in the Lean model." [ .labeled "Fee priority" (["Low", "Medium", "High"][m.fee]!), .identified "copiesValue" (.labeled "Copies" s!"{m.copies}") ]
      , .section "Controls" "" [ .picker "Fee" ["Low", "Medium", "High"] m.fee Msg.fee
                                , .identified "copies" (.stepper "Copies" m.copies 1 5 Msg.copies)
                                , .input .secure "Passphrase" "Optional" m.secret Msg.secret none
                                , .disclosure "Details" m.details Msg.details [.text "Hidden until expanded." .body] ]
      , .section "Share" "" [ .qr "bitcoin:tb1qexample", .share "Share address" "tb1qexample"
                             , .button "Open sheet" .primary (some .openSheet) ]
      -- a row's swipe actions (`Decor.swipe`) and its context menu (`Decor.menu`): buttons of the row that are
      -- not drawn in it. The list's last section, so the rows above stand where the journeys and tests expect
      -- them. A full swipe from the trailing edge archives; the disabled one is no swipe action. The menu (a
      -- right click on a Mac, a long press on a phone) has Archive and Delete too, one of its own, and a disabled
      -- one, greyed
      , .section "Swipe" "Swipe the row from either edge, or open its menu."
          [ .col [ .identified "swipeRow" (.text "A row with swipe actions" .body)
                 , .identified "swipedValue" (Html.tone .secondary (.text m.swiped .caption))
                 , Html.inMenu (Html.swipe .trailing (Html.symbol "archivebox" (.identified "swipe-archive" (.button "Archive" .primary (some (.swiped "Archived"))))))
                 , Html.inMenu (Html.swipe .trailing (Html.symbol "trash" (.identified "swipe-delete" (.button "Delete" .destructive (some (.swiped "Deleted"))))))
                 , Html.swipe .trailing (.button "Never" .plain none)
                 , Html.swipe .leading (Html.symbol "flag" (Html.tone .warning (.identified "swipe-flag" (.button "Flag" .plain (some (.swiped "Flagged"))))))
                 , Html.inMenu (Html.symbol "envelope.badge" (.identified "menu-unread" (.button "Mark unread" .plain (some (.swiped "Marked unread")))))
                 , Html.inMenu (.identified "menu-locked" (.button "Locked" .plain none)) ]
            -- a row's click with a modifier key held (`Decor.pointer`): the row opens on a plain click, and with
            -- command (or control) or shift held it does the button of the row that names that key, which is not
            -- drawn. The disabled one does nothing, and the plain click is not done in its place
          , .col [ .row [ Html.decor { chevron := true } (.identified "pickRow" (.button "A row to pick" .plain (some (.swiped "Opened")))) ]
                 , Html.onClickWith "cmd" (.identified "pick-one" (.button "Pick" .plain (some (.swiped "Picked"))))
                 , Html.onClickWith "shift" (.identified "pick-run" (.button "Pick to here" .plain (some (.swiped "Picked to here")))) ] ] ]
    , (if m.sheet then .sheet "A sheet" (some .closeSheet)
        [ .text "Swipe down or tap Close." .body, .button "Close" .plain (some .closeSheet)
        , .identified "sheetPush" (.button "Open a screen" .plain (some .openPushed)) ] else .spacer)
    , (if m.alert then .alert "An alert" "Rendered from a Lean `alert` node." [.button "OK" .plain (some .closeAlert)] else .spacer) ]

/-- The screen the sheet's button opens, pushed over the Widgets tab's (`depth`): with the newest line of the
log, which is the echo's answer once the view after the push has come. -/
def pushedView (m : Model) : Html Msg :=
  .screen "Pushed" (some .closePushed)
    [ .identified "pushedText" (.text "Opened from the sheet." .body)
    , .identified "pushedLog" (.text (m.log.head?.getD "Nothing yet") .caption) ]
    (largeTitle := false) (depth := 1)

def probesView (m : Model) : Html Msg :=
  .screen "Probes" none
    [ .list
      ([ .section "Capabilities" "Each button asks the shell; the answer is logged below."
          (probes.zipIdx.map fun ((l, _, _), i) => .identified s!"probe-{i}" (.button l .plain (some (.probe i)))) ]
      -- only with NATIVEDEMO_BLE_SERVICE: otherwise the list is as it always was
      ++ (match m.bleService with
          | some s => [.section "Bluetooth" s!"The first peripheral offering {s} (NATIVEDEMO_BLE_SERVICE); connected, logged and closed."
              [ .identified "ble-state" (.button "BLE state" .plain (some .bleState))
              , .identified "ble-connect" (.button "BLE connect" .plain (some .bleConnect)) ]]
          | none => [])
      ++ [.section "Log" "Newest first, with system events." (m.log.map (fun s => .text s .caption))]) ]

def boxes : List String := ["Inbox", "Archive"]

/-- `Html.split`: a sidebar, a list and what the list's choice shows, side by side in a wide window (an iPad, a
Mac), one at a time in a narrow one, where going back from a column is that screen's `onBack`. -/
def columnsView (m : Model) (shown : Nat) : Html Msg :=
  let box := boxes[m.box]?.getD "?"
  .split shown
    [ .screen "Boxes" none
        [ .list [ .section "" "" (boxes.zipIdx.map fun (l, i) =>
            Html.chosen (i == m.box) (.identified s!"box-{i}" (.button l .plain (some (.box i)))))
                , .section "" "" [ .identified "closeColumns" (.button "Back to the tabs" .plain (some (.columns none))) ] ] ]
    , .screen box (some (.columns (some 0)))
        [ .list [ .section "" "" ((List.range 3).map fun i =>
            Html.chosen (i == m.item) (.identified s!"item-{i}" (.button s!"{box} item {i + 1}" .plain (some (.item i))))) ] ]
        (largeTitle := false)
    , .screen s!"Item {m.item + 1}" (some (.columns (some 1)))
        [ .toolbar [ Html.key "cmd+k" (Html.symbol "plus" (.identified "columnInc" (.button "+1" .plain (some .inc)))) ]
        , .identified "columnItem" (.text s!"{box} item {m.item + 1}" .title)
        , .identified "columnCount" (.text s!"Count: {m.count}" .body) ]
        (largeTitle := false) ]

def view (m : Model) : Html Msg :=
  if let some shown := m.columns then columnsView m shown else
  .tabs ["Demo", "Widgets", "Probes"] ["sparkles", "slider.horizontal.3", "stethoscope"] m.tab Msg.tab
    [if m.tab == 0 then .screen "Native mode" none [demoView m] else if m.tab == 1 then (if m.pushed then pushedView m else widgets m) else probesView m]

open Std Async Net in
def echoOnce (port : UInt16) (text : String) : IO String := do
  let addr : SocketAddress := .v4 ⟨IPv4Addr.ofParts 127 0 0 1, port⟩
  let server ← TCP.Socket.Server.mk
  server.bind addr
  server.listen 1
  let serve : Async Unit := do
    let c ← server.accept
    let some msg ← c.recv? 1024 | pure ()
    c.send ("echo: ".toUTF8 ++ msg)
  let _ ← IO.asTask serve.block
  let client ← TCP.Socket.Client.mk
  let ask : Async (Option ByteArray) := do
    client.connect addr
    client.send text.toUTF8
    client.recv? 1024
  let reply ← ask.block
  pure (String.fromUTF8! (reply.getD .empty))

open Std Async Net in
/-- The head of an HTTP request, read from a connection: up to its blank line, or what came before the end. -/
partial def requestHead (c : TCP.Socket.Client) (head : ByteArray := .empty) : Async ByteArray := do
  if (((String.fromUTF8? head).getD "").splitOn "\r\n\r\n").length > 1 then return head
  match ← c.recv? 4096 with
  | some more => requestHead c (head ++ more)
  | none => return head

open Std Async Net in
/-- A local HTTP server for the selftest, on a free port of 127.0.0.1 (the simulator shares the Mac's ports):
one connection at a time, `respond` writing the answer to the request's path, a failure being that
connection's alone. Answers its port and what stops it. -/
def localHttp (respond : String → TCP.Socket.Client → Async Unit) : IO (UInt16 × IO Unit) := do
  let addr (port : UInt16) : SocketAddress := .v4 ⟨IPv4Addr.ofParts 127 0 0 1, port⟩
  let server ← TCP.Socket.Server.mk
  server.bind (addr 0)
  server.listen 8
  let port := (← server.getSockName).port
  let stopped ← IO.mkRef false
  let answerOne (c : TCP.Socket.Client) : Async Unit := do
    let head := (String.fromUTF8? (← requestHead c)).getD ""
    respond ((head.splitOn " ")[1]?.getD "") c
    c.shutdown
  let rec serve : Nat → Async Unit
    | 0 => pure ()
    | left + 1 => do
      let c ← server.accept
      if ← stopped.get then return
      try answerOne c catch _ => pure ()
      serve left
  -- a thread of its own: it waits in `accept` between requests
  discard <| IO.asTask (prio := .dedicated) (serve 64).block
  -- the server leaves `accept` at the next connection: this one
  let stop : IO Unit := do
    stopped.set true
    let c ← TCP.Socket.Client.mk
    (c.connect (addr port)).block
  pure (port, stop)

/-- An HTTP/1.1 answer's head (the connection closes after it) and its body. -/
def httpAnswer (status : String) (headers : List String) (body : String) : ByteArray :=
  ("\r\n".intercalate ([s!"HTTP/1.1 {status}", "Content-Type: application/octet-stream", "Connection: close"] ++ headers)
    ++ "\r\n\r\n" ++ body).toUTF8

/-- The session: what runs while the app is in front. Going to the background ends it. -/
initialize session : EffectScope ← EffectScope.new

/-- The background tasks iOS launched and the app has not finished. -/
initialize backgroundTasks : BackgroundTasks ← BackgroundTasks.new

/-- The demo's background job: `steps` short steps, stopping between them once cancelled. -/
def backgroundWork (steps : Nat) : IO Bool := do
  for _ in [0:steps] do
    if ← IO.checkCanceled then return false
    IO.sleep 200
  return true

/-- Work that never finishes by itself: it stops only when the run cancels it. -/
def untilCancelled : IO Bool := do
  while !(← IO.checkCanceled) do IO.sleep 20
  return true

def describe (o : BackgroundRun.Outcome) : String :=
  let ended := match o.ended with
    | .completed => "completed" | .unfinished => "unfinished" | .failed e => s!"failed ({e})" | .expired => "expired"
  s!"{ended}, work {if o.workStarted then "started" else "never started"}, success {o.success}"
/-- A typed client's result, for the selftest's output. -/
def shown (r : Client.Result α) (render : α → String) : String :=
  match r with
  | .ok a => s!"ok {render a}"
  | .error e => s!"{e.kind.name} {e.name}{match e.code with | some c => s!" ({c})" | none => ""}"

/-- The typed clients against the real shell: an atomic create-only Keychain item, read and deleted; an
HTTP request the shell refuses; the CloudKit account (an ad-hoc build has no entitlement). -/
def typedSelftest (fx : Effects Host) (say : String → IO Unit) : IO Unit := do
  let item : Client.Keychain.Item := { key := "typed", service := some "art.fralex.leannative.nativedemo.probe" }
  let bytes := ByteArray.mk #[1, 2, 3]
  let hex := fun (b : Option ByteArray) => (b.map Client.hexOf).getD "none"
  let added := fun (a : Client.Keychain.Added) => match a with | .added => "added" | .alreadyExists => "alreadyExists"
  discard <| (Client.Keychain.delete item).call fx
  say s!"typed keychain.add: {shown (← (Client.Keychain.add item bytes).call fx) added}"
  say s!"typed keychain.add again: {shown (← (Client.Keychain.add item (ByteArray.mk #[9])).call fx) added}"
  say s!"typed keychain.get: {shown (← (Client.Keychain.get item).call fx) hex}"
  say s!"typed keychain.delete: {shown (← (Client.Keychain.delete item).call fx) fun _ => ""}"
  say s!"typed keychain.get after delete: {shown (← (Client.Keychain.get item).call fx) hex}"
  say s!"typed http.get ftp: {shown (← (Client.Http.get { url := "ftp://example.com/" }).call fx) fun r => toString r.status}"
  say s!"typed http.get unreachable: {shown (← (Client.Http.get { url := "http://127.0.0.1:1/", timeout := some 5 }).call fx) fun r => toString r.status}"
  say s!"typed cloudkit.account: {shown (← (Client.CloudKit.account).call fx) fun a => (a.user.getD "no user")}"
  -- many records in one request: refused for its arguments before CloudKit is asked, and for the entitlement
  say s!"typed cloudkit.loadMany none: {shown (← (Client.CloudKit.loadMany #[]).call fx) fun m => toString m.records.size}"
  say s!"typed cloudkit.loadMany: {shown (← (Client.CloudKit.loadMany #["a", "b"] (files := true)).call fx) fun m => toString m.records.size}"
  -- Apple's push: no entitlement here, so no token and Apple not asked; and no notice is pending
  say s!"typed push.register: {shown (← Client.Push.register.call fx) fun t => t.environment.name}"
  say s!"typed push.complete none: {shown (← (Client.Push.complete 1).call fx) toString}"

/-- `keychain.set` against the real Keychain: an item that is not there is made, one that is there is given its
new value in place, and what `get` reads afterwards is what was set. (That a refused write leaves the old value
cannot be shown here: nothing makes the simulator's Keychain refuse one.) -/
def keychainSetSelftest (fx : Effects Host) (say : String → IO Unit) : IO Unit := do
  let item : Client.Keychain.Item := { key := "typed-set", service := some "art.fralex.leannative.nativedemo.probe" }
  let hex := fun (b : Option ByteArray) => (b.map Client.hexOf).getD "none"
  discard <| (Client.Keychain.delete item).call fx
  say s!"typed keychain.set: {shown (← (Client.Keychain.set item (ByteArray.mk #[10, 11])).call fx) fun _ => "set"}"
  say s!"typed keychain.get after set: {shown (← (Client.Keychain.get item).call fx) hex}"
  say s!"typed keychain.set again: {shown (← (Client.Keychain.set item (ByteArray.mk #[12])).call fx) fun _ => "set"}"
  say s!"typed keychain.get after set again: {shown (← (Client.Keychain.get item).call fx) hex}"
  -- an item `add` made is `set`'s to replace too, and stays the only one of its name
  discard <| (Client.Keychain.delete item).call fx
  discard <| (Client.Keychain.add item (ByteArray.mk #[1])).call fx
  say s!"typed keychain.set over add: {shown (← (Client.Keychain.set item (ByteArray.mk #[13, 14])).call fx) fun _ => "set"}"
  say s!"typed keychain.get after set over add: {shown (← (Client.Keychain.get item).call fx) hex}"
  discard <| (Client.Keychain.delete item).call fx
  say s!"typed keychain.get after set and delete: {shown (← (Client.Keychain.get item).call fx) hex}"

/-- One question to the person at a time: the selftest's kept authentication and the Face ID button's (or
`NATIVEDEMO_AUTH_AFTER`'s) wait for each other, since the system cancels a sheet another one covers. -/
initialize asking : Std.BaseMutex ← Std.BaseMutex.new

/-- `keychain-user-presence`: an item behind the person's presence (`access := .userPresence`), against the real
Keychain. One item is added behind it and its attributes read back; another, added without, is upgraded in
place (`protect`, twice: the second changes nothing); neither is read without an authentication (`-25308`, and
nobody is asked), and `set` neither rewrites the first nor makes such an item. With `NATIVEDEMO_KEYCHAIN_PROMPT`
set at launch the person is asked once (`auth` with `keep`), both items are read under that one answer, and the
first is refused again after `auth.end`. A read under a kept authentication cannot have asked again: the shell
keeps it allowing no interaction, so a read it did not satisfy would have been refused. No value is printed.

The last line, `keychain-user-presence: <verdict>: …`, says each of those plainly. Its verdict is

* `PASS`: every one shown;
* `PASS WITHOUT THE PROMPT`: all that needs no person (no `NATIVEDEMO_KEYCHAIN_PROMPT`);
* `NOT ENFORCED`: the Keychain took the access control and gave the values without an authentication, as a
  simulator's does (it has no Secure Enclave to hold one to): on a device this is a failure;
* `SIMULATOR FALLBACK`: the shell stored the item unlocked and said so (a simulator whose Keychain refuses an
  access control for want of a passcode);
* `UNSUPPORTED`: no Keychain at all (an ad-hoc Mac app);
* `FAIL`: anything else.

It leaves no item behind. -/
def keychainUserPresenceSelftest (fx : Effects Host) (say : String → IO Unit) : IO Unit := do
  let service := "art.fralex.leannative.nativedemo.presence"
  let line (what answer : String) : IO Unit := say s!"keychain-user-presence {what}: {answer}"
  let fresh : Client.Keychain.Item := { key := "fresh", service := some service, access := .userPresence }
  let upgraded : Client.Keychain.Item := { key := "upgraded", service := some service }
  let freshBytes := ByteArray.mk #[1, 2, 3]
  let upgradedBytes := ByteArray.mk #[10, 11]
  let value (expected : ByteArray) (b : Option ByteArray) : String := match b with
    | some b => if b == expected then "the value it was given" else "ANOTHER VALUE"
    | none => "none"
  let isValue (expected : ByteArray) (r : Client.Result (Option ByteArray)) : Bool := match r with
    | .ok (some b) => b == expected
    | _ => false
  let refused (r : Client.Result (Option ByteArray)) : Bool := match r with
    | .error e => e.code == some Client.Keychain.errSecInteractionNotAllowed
    | .ok _ => false
  let status (code : Int) (r : Client.Result Unit) : Bool := match r with
    | .error e => e.code == some code
    | .ok _ => false
  let attributes := fun (a : Option Client.Keychain.Attributes) => match a with
    | some a => s!"userPresence {a.userPresence}, accessible {a.accessible.getD "(not said)"}, synchronizable {a.synchronizable}"
    | none => "none"
  let flagged (r : Client.Result (Option Client.Keychain.Attributes)) : Bool := match r with
    | .ok (some a) => a.userPresence
    | _ => false
  let yes (b : Bool) := if b then "yes" else "NO"
  -- how a read without an authentication ended: the status that refused it, or that it was read
  let how := fun (r : Client.Result (Option ByteArray)) => match r with
    | .error e => (e.code.map fun c => s!" ({c})").getD s!" ({e.name})"
    | .ok _ => " (it was read)"
  discard <| (Client.Keychain.clear service).call fx
  -- an item added behind the person's presence, and what protects it read back
  let added ← (Client.Keychain.addApplied fresh freshBytes).call fx
  line "add" (shown added fun (a, access) => s!"{match a with | .added => "added" | .alreadyExists => "alreadyExists"}, access {access.name}")
  if let .error e := added then
    if e.kind == .unsupported then
      say s!"keychain-user-presence: UNSUPPORTED: no Keychain here ({e.name}); nothing was stored"
      return
  let applied := added matches .ok (.added, .userPresence)
  let fellBack := added matches .ok (.added, .unlocked)
  let freshAttributes ← (Client.Keychain.attributes fresh).call fx
  line "attributes" (shown freshAttributes attributes)
  -- an item that was there without it, upgraded in place; a second upgrade changes nothing
  discard <| (Client.Keychain.add upgraded upgradedBytes).call fx
  line "attributes before protect" (shown (← (Client.Keychain.attributes upgraded).call fx) attributes)
  let protect ← (Client.Keychain.protect upgraded).call fx
  line "protect" (shown protect fun changed => s!"changed {changed}")
  let again ← (Client.Keychain.protect upgraded).call fx
  line "protect again" (shown again fun changed => s!"changed {changed}")
  let upgradedAttributes ← (Client.Keychain.attributes upgraded).call fx
  line "attributes after protect" (shown upgradedAttributes attributes)
  -- `set` neither rewrites such an item nor makes one, and an item that syncs cannot be one
  let setOver ← if applied then (Client.Keychain.set { fresh with access := .unlocked } (ByteArray.mk #[9])).call fx
    else pure (.error (Client.failed "not tried" "the item is not behind an access control here"))
  line "set over it" (shown setOver fun _ => "SET")
  let setAsking ← (Client.Keychain.set { fresh with key := "set" } (ByteArray.mk #[9])).call fx
  line "set asking for it" (shown setAsking fun _ => "SET")
  let cloud ← (Client.Keychain.add { fresh with key := "cloud", synchronizable := true } (ByteArray.mk #[9])).call fx
  line "add synchronizable" (shown cloud fun _ => "ADDED")
  let nothingMade := ((← (Client.Keychain.attributes { fresh with key := "set" }).call fx) matches .ok none)
    && ((← (Client.Keychain.attributes { fresh with key := "cloud", synchronizable := true }).call fx) matches .ok none)
  let refusals := status (-50) setAsking && (cloud matches .error { code := some (-50), .. }) && nothingMade
    && (!applied || status Client.Keychain.errSecInteractionNotAllowed setOver)
  -- neither is read without an authentication: refused, and nobody asked
  let bare ← (Client.Keychain.get fresh).call fx
  line "get without a context" (shown bare (value freshBytes))
  let bareUpgraded ← (Client.Keychain.get upgraded).call fx
  line "get of the upgraded item without a context" (shown bareUpgraded (value upgradedBytes))
  let stranger ← (Client.Keychain.get fresh (context := some "00000000-0000-0000-0000-000000000000")).call fx
  line "get with a context that never was" (shown stranger (value freshBytes))
  let enforced := refused bare && refused bareUpgraded && refused stranger
  -- read all the same, each its own value: the Keychain here holds no item to its access control
  let unenforced := isValue freshBytes bare && isValue upgradedBytes bareUpgraded && isValue freshBytes stranger
  -- the person, once: both items read under the one answer, and refused again once it has ended
  let prompt := ((← IO.getEnv "NATIVEDEMO_KEYCHAIN_PROMPT").getD "") != ""
  let mut read := false
  let mut second := false
  let mut ended := "not asked"
  let mut endedRefused := false
  let mut asked := "not asked (launch with NATIVEDEMO_KEYCHAIN_PROMPT=1)"
  if prompt then
    asking.lock
    let auth ← try (Client.Auth.authenticate "Read two Keychain items behind your presence, asking you once" (keep := some 30)).call fx
      finally asking.unlock
    line "auth with keep" (shown auth fun s => s!"{if s.context.isSome then "a context kept" else "NOTHING KEPT"}{match s.note with | some n => s!" ({n})" | none => ""}")
    match auth with
    | .error e => asked := s!"NO ({e.kind.name} {e.name})"
    | .ok { context := none, .. } => asked := "NO (nothing kept)"
    | .ok { context := some context, .. } =>
      let first ← (Client.Keychain.get fresh (context := some context)).call fx
      line "get with the context" (shown first (value freshBytes))
      let next ← (Client.Keychain.get upgraded (context := some context)).call fx
      line "second get with the same context" (shown next (value upgradedBytes))
      line "auth.end" (shown (← (Client.Auth.end context).call fx) fun _ => "ended")
      let after ← (Client.Keychain.get fresh (context := some context)).call fx
      line "get after auth.end" (shown after (value freshBytes))
      read := isValue freshBytes first
      second := isValue upgradedBytes next
      endedRefused := refused after
      ended := yes endedRefused ++ how after
      asked := yes read
  -- nothing left behind
  discard <| (Client.Keychain.clear service).call fx
  let cleaned := ((← (Client.Keychain.attributes fresh).call fx) matches .ok none)
    && ((← (Client.Keychain.attributes upgraded).call fx) matches .ok none)
  line "cleanup" (if cleaned then "ok nothing left" else "ITEMS LEFT")
  let readBack := flagged freshAttributes
  let upgradedInPlace := (protect matches .ok true) && (again matches .ok false) && flagged upgradedAttributes
  let stored := applied && readBack && upgradedInPlace && refusals && cleaned
  let verdict :=
    if fellBack then
      -- the shell said the item is unlocked, and everything agrees with that
      if !readBack && (protect matches .ok false) && (again matches .ok false) && !flagged upgradedAttributes && unenforced
          && refusals && cleaned && (!prompt || (read && second)) then "SIMULATOR FALLBACK" else "FAIL"
    else if !stored then "FAIL"
    else if !enforced then (if unenforced && (!prompt || (read && second)) then "NOT ENFORCED" else "FAIL")
    else if !prompt then "PASS WITHOUT THE PROMPT"
    else if read && second && endedRefused then "PASS" else "FAIL"
  let appliedSaid := if fellBack then "no, the shell stored it unlocked and said so (a simulator without a passcode)" else yes applied
  let upgradeSaid := if fellBack && (protect matches .ok false) then "no, the shell left it unlocked and said so" else yes upgradedInPlace
  let enforcedSaid := if enforced then "yes" else if stored && unenforced then "NO, the Keychain here does not hold an item to its access control, as a simulator's does not"
    else "NO"
  say s!"keychain-user-presence: {verdict}: flag applied: {appliedSaid}; flag read back: {yes readBack}; in-place upgrade worked: {upgradeSaid}; unauthenticated read refused: {enforcedSaid}{how bare}; authenticated read with a kept context after ONE prompt: {asked}; second read under the same context with no second prompt: {if prompt then yes second else "not asked"}; refused again after auth.end: {ended}; set and synchronizable refusals: {yes refusals}; left nothing behind: {yes cleaned}"

open Std Async Net in
/-- The shell's `http.*` against two servers of the selftest's own, `site` and `other`, on two ports of
127.0.0.1: a redirect within `site` is followed and one from `other` to `site` (the same host, another port) is
not; a body the server declares to be over `maxBytes` is refused without waiting for it; and a body that never
ends is refused once it has passed `maxBytes`, the server's sending cut short (it would send `whole` bytes). -/
def httpSelftest (fx : Effects Host) (say : String → IO Unit) : IO Unit := do
  let whole := 64 * 1024 * 1024
  let sent ← IO.mkRef (none : Option Nat)
  let (site, stopSite) ← localHttp fun path c => do
    match path with
    | "/hop" => c.send (httpAnswer "302 Found" ["Location: /landed", "Content-Length: 5"] "moved")
    | "/landed" => c.send (httpAnswer "200 OK" ["Content-Length: 6"] "landed")
    | "/declared" =>
      -- five megabytes promised, sixteen bytes sent; then it waits for the client to go
      c.send (httpAnswer "200 OK" ["Content-Length: 5000000"] "0123456789abcdef")
      discard <| c.recv? 1
    | "/endless" =>
      -- no length: the body is whatever comes until the connection closes
      c.send (httpAnswer "200 OK" [] "")
      let chunk := ByteArray.mk (Array.replicate 65536 120)
      let mut n := 0
      try
        while n < whole do
          c.send chunk
          n := n + chunk.size
      catch _ => pure ()
      sent.set (some n)
    | _ => c.send (httpAnswer "404 Not Found" ["Content-Length: 0"] "")
  let (other, stopOther) ← localHttp fun _ c =>
    c.send (httpAnswer "302 Found" [s!"Location: http://127.0.0.1:{site}/landed", "Content-Length: 5"] "moved")
  let page := fun (r : Client.Http.Response) => s!"{r.status} {(String.fromUTF8? r.body).getD "?"}"
  let get (url : String) (maxBytes : Nat := 1000) : IO (Client.Result Client.Http.Response) :=
    (Client.Http.get { url, maxBytes, timeout := some 5 }).call fx
  say s!"typed http.get redirect within the origin: {shown (← get s!"http://127.0.0.1:{site}/hop") page}"
  say s!"typed http.get redirect to another port: {shown (← get s!"http://127.0.0.1:{other}/") page}"
  say s!"typed http.get declared over maxBytes: {shown (← get s!"http://127.0.0.1:{site}/declared") page}"
  let request := (Client.Http.send { url := s!"http://127.0.0.1:{site}/declared", httpMethod := "POST", body := some "x".toUTF8, maxBytes := 1000, timeout := some 5 }).call fx
  say s!"typed http.request declared over maxBytes: {shown (← request) page}"
  say s!"typed http.get within maxBytes: {shown (← get s!"http://127.0.0.1:{site}/landed" 6) page}"
  let endless ← get s!"http://127.0.0.1:{site}/endless"
  -- the server stops when its connection is closed under it: at once if the shell cancelled the transfer
  let mut waited := 0
  while (← sent.get).isNone && waited < 100 do
    IO.sleep 100
    waited := waited + 1
  let server := match ← sent.get with
    | some n => if n < whole then "the server cut short" else "the server sent it all"
    | none => "the server still sending"
  say s!"typed http.get endless body: {shown endless page}, {server}"
  stopSite
  stopOther

def bleStateName : Client.Bluetooth.State → String
  | .poweredOn => "poweredOn" | .poweredOff => "poweredOff" | .unauthorized => "unauthorized"
  | .unsupported => "unsupported" | .resetting => "resetting" | .unknown => "unknown"

/-- A line of a run's evidence: stdout is what a hand check keeps. -/
def printed (line : String) : IO Unit := do
  let out ← IO.getStdout
  out.putStrLn line; out.flush

/-- A Bluetooth probe's answer: printed to stdout and logged. -/
def bleSay (fx : Effects Host) (line : String) : IO Unit := do
  printed s!"ble: {line}"
  fx.post (.bleSaid line)

def perform (c : Cmd) (fx : Effects Host) : IO Unit :=
  match c with
  -- for the app's life: a thread of its own, not a worker of Lean's task pool (`Native.App.perform`)
  | .ticker => discard <| IO.asTask (prio := .dedicated) do
      repeat
        IO.sleep 1000
        fx.post .tick
  | .auth => discard <| IO.asTask (prio := .dedicated) do
      -- in the session's scope: an answer after the app went to the background is not reported
      let token ← session.capture
      -- after the selftest's own question, if it is asking one
      asking.lock
      let r ← try session.authenticatedWithShell token fx "Prove native capabilities work" (pure ()) finally asking.unlock
      let stage := match r with
        | .stale .beforePrompt => "before the prompt" | .stale .afterAnswer => "after the answer"
        | .stale .duringAction => "during the action" | _ => "authentication"
      let (ok, detail) := match r with
        | .done () => (true, "")
        | .denied e => (false, s!"denied ({e.name})")
        | .cancelled e => (false, s!"cancelled ({e.name})")
        | .error e => (false, s!"{e.kind.name} ({e.name}{match e.code with | some c => s!" {c}" | none => ""}{match e.domain with | some d => s!" {d}" | none => ""})")
        | .failed e => (false, toString e)
        | .stale _ => (false, "stale")
      -- a stale answer is not the session's; it is noted apart, so a test can see it was dropped
      let answer := if ok then "authenticated" else s!"not authenticated: {detail}"
      unless ← session.deliver token (do printed s!"auth: {answer}"; fx.post (.authed ok detail)) do
        printed s!"auth: dropped a stale answer: {stage}"
        fx.post (.dropped stage)
  | .echo text => discard <| IO.asTask do
      let r ← try echoOnce 48334 text catch e => pure s!"failed: {e}"
      fx.post (.echoed r)
  | .probe l n a => fx.cap n a (.probed l)
  | .readClipboard => fx.cap "clipboard.get" (Json.mkObj []) fun j => .pasted ((j.getObjValAs? String "text").toOption.getD "")
  -- iOS gives a refresh task about 30 s; the run asks its work to stop after 20
  -- the launch's tag goes back with its `bgtask.complete`, so an older run's answer cannot end a newer task
  | .runBackground id kind tag => do
      printed s!"bgtask launched: {id} ({kind})"
      discard <| backgroundTasks.launch fx id (tag := tag)
        { work := backgroundWork 10, deadline := .after 20_000,
          completion := fun o => do printed s!"background run {id}: {describe o}"; fx.post (.ran id (describe o)) }
  | .expireBackground id tag => do
      printed s!"bgtask expired: {id}"
      backgroundTasks.expire id tag
  -- for hand checks that keep the output (`xcrun simctl push`): every push event is printed, and a notice
  -- whose payload says `"answer"` (`newData`, `noData`, `failed`) is answered so; one that says nothing is
  -- left for the shell to answer when its time is up (`pushExpired`, then `failed`)
  | .pushed j => discard <| IO.asTask do
      printed s!"push: {j.compress}"
      if let some (.received tag _ payload) := Client.Push.event? j then
        let outcome? := match (payload.getObjValAs? String "answer").toOption with
          | some "newData" => some Client.Push.Outcome.newData
          | some "noData" => some .noData
          | some "failed" => some .failed
          | _ => none
        if let some outcome := outcome? then
          printed s!"push.complete {tag}: {shown (← (Client.Push.complete tag outcome).call fx) toString}"
  | .bleSetup => do
      if let some s ← IO.getEnv "NATIVEDEMO_BLE_SERVICE" then
        if !s.isEmpty then fx.post (.bleService s)
  | .authSetup => do
      if let some s ← IO.getEnv "NATIVEDEMO_AUTH_AFTER" then
        if let some n := s.toNat? then
          discard <| IO.asTask (prio := .dedicated) do
            IO.sleep (n * 1000).toUInt32
            printed s!"auth: asking ({n} s after launch, NATIVEDEMO_AUTH_AFTER)"
            fx.post .authCue
  | .bleState => discard <| IO.asTask (prio := .dedicated) do
      bleSay fx s!"BLE state: {shown (← Client.Bluetooth.state.call fx) bleStateName}"
  | .bleConnect service => discard <| IO.asTask (prio := .dedicated) do
      match ← (Client.Bluetooth.connect [service] (some 90)).call fx with
      | .ok c =>
        bleSay fx s!"BLE connected: id {c.id}, name {c.name.getD "(none)"}, service {c.service}, {c.characteristics.size} characteristics"
        bleSay fx s!"BLE closed: {shown (← (Client.Bluetooth.close c.id).call fx) fun _ => ""}"
      | r => bleSay fx s!"BLE connect: {shown r fun _ => ""}"
  | .endSession => do
      printed "scene: background, the session's scope ends"
      discard <| IO.asTask (prio := .dedicated) session.invalidate
  | .selftest => do
      -- a headless check for runs nobody clicks through (`NATIVEDEMO_SELFTEST=1` in the launch
      -- environment): the TCP echo and every probe in order, each answer printed to stdout and logged
      let some _ ← IO.getEnv "NATIVEDEMO_SELFTEST" | pure ()
      discard <| IO.asTask do
        let out ← IO.getStdout
        let say (s : String) : IO Unit := do out.putStrLn s!"selftest: {s}"; out.flush; fx.post (.checked s)
        let r ← try echoOnce 48335 "selftest" catch e => pure s!"failed: {e}"
        say s!"TCP echo: {r}"
        fx.post (.echoed r)
        -- two runs that iOS did not launch: one completes, one never stops until its deadline expires it
        let quick ← BackgroundRun.new { work := backgroundWork 2, completion := fun _ => pure () }
        quick.start
        say s!"background run: {describe (← quick.wait)}"
        let hung ← BackgroundRun.new { work := untilCancelled, completion := fun _ => pure (), deadline := .after 300 }
        hung.start
        say s!"background run past its deadline: {describe (← hung.wait)}"
        -- a scope's task, cancelled and drained by its invalidation; its late result is dropped
        let scope ← EffectScope.new
        let token ← scope.capture
        let drained ← IO.mkRef false
        let spawned ← scope.spawn token (do discard untilCancelled; drained.set true)
        scope.invalidate
        let late ← scope.deliver token (pure ())
        say s!"effect scope: {if spawned matches .started _ then "started" else "stale"}, drained {← drained.get}, late result delivered {late}, now {← scope.liveTasks} tasks"
        typedSelftest fx say
        keychainSetSelftest fx say
        try keychainUserPresenceSelftest fx say catch e => say s!"keychain-user-presence: FAIL: {e}"
        try httpSelftest fx say catch e => say s!"http selftest: failed: {e}"
        -- the device's time zone: an identifier, and seconds east of UTC within a day either way
        let zone ← IO.wait (← fx.ask "timezone" (Json.mkObj []))
        let zoneOk := (zone.getObjValAs? String "id").isOk &&
          ((zone.getObjValAs? Int "offset").toOption.map fun o => -86400 < o && o < 86400).getD false
        say s!"timezone: {if zoneOk then "an identifier and an offset" else zone.compress}"
        -- the kind of machine: a phone, a pad or a Mac
        let device ← IO.wait (← fx.ask "device" (Json.mkObj []))
        let idiom := (device.getObjValAs? String "idiom").toOption.getD ""
        say s!"device: {if ["phone", "pad", "mac"].contains idiom then "an idiom" else device.compress}"
        -- what the device runs on: its power and its network, each one of the words the shell may say
        let conditions ← IO.wait (← fx.ask "conditions" (Json.mkObj []))
        let word (k : String) (among : List String) := ((conditions.getObjValAs? String k).toOption.map among.contains).getD false
        let flag (k : String) := (conditions.getObjValAs? Bool k).isOk
        let conditionsOk := word "power" ["charging", "full", "battery", "unknown"]
          && word "network" ["wifi", "wired", "cellular", "other", "none", "unknown"]
          && flag "lowPower" && flag "expensive" && flag "constrained"
        say s!"conditions: {if conditionsOk then "a power and a network" else conditions.compress}"
        for (l, n, a) in probes do
          let j ← IO.wait (← fx.ask n a)
          say s!"{l}: {j.compress}"
          fx.post (.probed l j)
        say "done"

def app : Native.App Model Msg Cmd Host :=
  { init := { count := 0, ticks := 0, ticking := false, log := [] }, update, view, cmds, host := Msg.host, perform, boot := [.selftest, .bleSetup, .authSetup],
    -- every system event but a scene phase is logged (the Probes tab shows bgtask launches and expirations); of
    -- the scene phases, going to the background and coming back from it are
    system := fun j =>
      if (j.getObjValAs? String "scene").toOption == some "background" then some .background
      else if (j.getObjValAs? String "scene").toOption == some "active" then some .foreground
      else if (j.getObjVal? "scene").isOk then none
      else if (Client.Push.event? j).isSome then some (.push j)
      else match BackgroundTasks.systemEvent? j with
        | some e => some (.bgtask e.expired e.id e.kind e.tag)
        | none => some (.system j) }

initialize Native.register app

end NativeDemo
