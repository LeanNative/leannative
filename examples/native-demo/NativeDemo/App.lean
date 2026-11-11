import Std.Async.TCP
import LeanNative.Native
import LeanNative.Native.BackgroundRun
import LeanNative.Native.EffectScope
import LeanNative.Native.Client.Keychain
import LeanNative.Native.Client.Http
import LeanNative.Native.Client.CloudKit
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
  invalidation drains, and the typed clients (`LeanNative.Native.Client.*`) against the real shell; its lines
  are printed and shown on the Demo tab (`selftest-<n>`), so UI tests read them on iOS and Mac Catalyst alike;
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
  /-- the columns (`Html.split`) in place of the tabs, and which of them a narrow window shows -/
  columns : Option Nat := none
  /-- the box chosen in the sidebar, and the item chosen in its list -/
  box : Nat := 0
  item : Nat := 0
  details : Bool := false
  secret : String := ""
  sheet : Bool := false
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

inductive Msg where
  | inc
  | startTicks
  | authenticate
  | echo
  | tab (i : Nat)
  | fee (i : Nat)
  | copies (n : Nat)
  | swiped (what : String)
  | columns (shown : Option Nat)
  | box (i : Nat)
  | item (i : Nat)
  | details (b : Bool)
  | secret (s : String)
  | openSheet
  | closeSheet
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
  | echo (text : String)
  | probe (label name : String) (args : Json)
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
      Json.mkObj [("url", "https://example.com/"), ("socks", Json.mkObj [("host", ""), ("port", (0 : Nat))])]) ]

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
  | .columns shown, m => { m with columns := shown }
  -- a choice in one column shows the next (which is all a narrow window has room for)
  | .box i, m => { m with box := i, item := 0, columns := some 1 }
  | .item i, m => { m with item := i, columns := some 2 }
  | .details b, m => { m with details := b }
  | .secret s, m => { m with secret := s }
  | .openSheet, m => { m with sheet := true }
  | .closeSheet, m => { m with sheet := false }
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
  | .echo, m => [.echo s!"ping {m.count}"]
  | .probe i, _ => match probes[i]? with
    | some (l, n, a) => [.probe l n a]
    | none => []
  | .bleState, _ => [.bleState]
  | .bleConnect, m => match m.bleService with
    | some s => [.bleConnect s]
    | none => []
  | .host (.bgtask false id kind tag), _ => [.runBackground id kind tag]
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
                 , Html.inMenu (.identified "menu-locked" (.button "Locked" .plain none)) ] ] ]
    , (if m.sheet then .sheet "A sheet" (some .closeSheet) [.text "Swipe down or tap Close." .body, .button "Close" .plain (some .closeSheet)] else .spacer)
    , (if m.alert then .alert "An alert" "Rendered from a Lean `alert` node." [.button "OK" .plain (some .closeAlert)] else .spacer) ]

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
    [if m.tab == 0 then .screen "Native mode" none [demoView m] else if m.tab == 1 then widgets m else probesView m]

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
      let r ← session.authenticatedWithShell token fx "Prove native capabilities work" (pure ())
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
        -- the device's time zone: an identifier, and seconds east of UTC within a day either way
        let zone ← IO.wait (← fx.ask "timezone" (Json.mkObj []))
        let zoneOk := (zone.getObjValAs? String "id").isOk &&
          ((zone.getObjValAs? Int "offset").toOption.map fun o => -86400 < o && o < 86400).getD false
        say s!"timezone: {if zoneOk then "an identifier and an offset" else zone.compress}"
        -- the kind of machine: a phone, a pad or a Mac
        let device ← IO.wait (← fx.ask "device" (Json.mkObj []))
        let idiom := (device.getObjValAs? String "idiom").toOption.getD ""
        say s!"device: {if ["phone", "pad", "mac"].contains idiom then "an idiom" else device.compress}"
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
      else match BackgroundTasks.systemEvent? j with
        | some e => some (.bgtask e.expired e.id e.kind e.tag)
        | none => some (.system j) }

initialize Native.register app

end NativeDemo
