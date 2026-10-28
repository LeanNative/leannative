import Std.Async.TCP
import ElmLean.Native

/-! # A native-mode demo: the pieces Winnow needs, in one screen

* `update`/`view`/`cmds` as in any ElmLean app;
* a command run by a Lean task that answers every second (`tick`);
* a command that asks the shell for an iOS capability (`auth`: Face ID or the passcode);
* a command that talks TCP through Lean's own libuv sockets (an echo server and client in-process);
* a Probes tab that asks the shell for capabilities (background tasks, CloudKit, iCloud Keychain, HTTP
  through a SOCKS5 proxy at 127.0.0.1:1080) and logs their answers and the system events. -/

namespace NativeDemo
open ElmLean ElmLean.Native Lean

structure Model where
  count : Nat
  ticks : Nat
  ticking : Bool
  log : List String
  tab : Nat := 0
  fee : Nat := 1
  copies : Nat := 1
  details : Bool := false
  secret : String := ""
  sheet : Bool := false
  alert : Bool := false
  deriving Inhabited

inductive Host where
  | tick
  | authed (ok : Bool) (detail : String)
  | echoed (reply : String)
  | probed (label : String) (result : Json)
  | system (event : Json)

inductive Msg where
  | inc
  | startTicks
  | authenticate
  | echo
  | tab (i : Nat)
  | fee (i : Nat)
  | copies (n : Nat)
  | details (b : Bool)
  | secret (s : String)
  | openSheet
  | closeSheet
  | openAlert
  | closeAlert
  | probe (i : Nat)
  | host (h : Host)

inductive Cmd where
  | ticker
  | auth
  | echo (text : String)
  | probe (label name : String) (args : Json)
  /-- at launch: with `NATIVEDEMO_SELFTEST` set, the TCP echo and every probe, answers printed -/
  | selftest
  deriving ToJson

/-- The Probes tab: a label, a capability and its arguments. The background task identifiers are the
demo's Info.plist `BGTaskSchedulerPermittedIdentifiers`. -/
def probes : List (String × String × Json) :=
  let refresh := "art.fralex.elmlean.nativedemo.refresh"
  let processing := "art.fralex.elmlean.nativedemo.processing"
  let probeService := "art.fralex.elmlean.nativedemo.probe"
  [ ("Refresh status", "bgtask.refreshStatus", Json.mkObj []),
    ("Schedule refresh", "bgtask.schedule", Json.mkObj [("id", refresh), ("after", (900 : Nat))]),
    ("Schedule processing", "bgtask.schedule",
      Json.mkObj [("id", processing), ("kind", "processing"), ("requiresNetwork", true)]),
    ("Schedule unlisted id", "bgtask.schedule", Json.mkObj [("id", "not.in.info.plist")]),
    ("Complete (none pending)", "bgtask.complete", Json.mkObj [("id", refresh), ("success", true)]),
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
  | .details b, m => { m with details := b }
  | .secret s, m => { m with secret := s }
  | .openSheet, m => { m with sheet := true }
  | .closeSheet, m => { m with sheet := false }
  | .openAlert, m => { m with alert := true }
  | .closeAlert, m => { m with alert := false }
  | .probe i, m => note m s!"asking: {(probes[i]?.map (·.1)).getD "?"}…"
  | .host .tick, m => { m with ticks := m.ticks + 1 }
  | .host (.authed ok d), m => note m (if ok then s!"authenticated {d}" else s!"not authenticated: {d}")
  | .host (.echoed r), m => note m s!"TCP echo: {r}"
  | .host (.probed l r), m => note m s!"{l}: {r.compress}"
  | .host (.system e), m => note m s!"system: {e.compress}"

def cmds : Msg → Model → List Cmd
  | .startTicks, m => if m.ticking then [] else [.ticker]
  | .authenticate, _ => [.auth]
  | .echo, m => [.echo s!"ping {m.count}"]
  | .probe i, _ => match probes[i]? with
    | some (l, n, a) => [.probe l n a]
    | none => []
  | _, _ => []

def demoView (m : Model) : Html Msg :=
  .col ([ .text "Native mode" .title
        , .text "This screen is Lean compiled to C, running inside the iOS app." .caption
        , .row [.text s!"Count: {m.count}" .body, .spacer, .button "+1" .primary (some .inc)]
        , .row [.text s!"Ticks from a Lean task: {m.ticks}" .body, .spacer,
                .button "Start" .plain (if m.ticking then none else some .startTicks)]
        , .row [.button "Face ID" .plain (some .authenticate), .button "TCP echo" .plain (some .echo)]
        , .divider ] ++ m.log.map (fun s => .text s .caption))

def widgets (m : Model) : Html Msg :=
  .screen "Widgets" none
    [ .toolbar [.button "Alert" .plain (some .openAlert)]
    , .list
      [ .section "Values" "Every value below lives in the Lean model." [ .labeled "Fee priority" (["Low", "Medium", "High"][m.fee]!), .labeled "Copies" s!"{m.copies}" ]
      , .section "Controls" "" [ .picker "Fee" ["Low", "Medium", "High"] m.fee Msg.fee
                                , .stepper "Copies" m.copies 1 5 Msg.copies
                                , .input .secure "Passphrase" "Optional" m.secret Msg.secret none
                                , .disclosure "Details" m.details Msg.details [.text "Hidden until expanded." .body] ]
      , .section "Share" "" [ .qr "bitcoin:tb1qexample", .share "Share address" "tb1qexample"
                             , .button "Open sheet" .primary (some .openSheet) ] ]
    , (if m.sheet then .sheet "A sheet" (some .closeSheet) [.text "Swipe down or tap Close." .body, .button "Close" .plain (some .closeSheet)] else .spacer)
    , (if m.alert then .alert "An alert" "Rendered from a Lean `alert` node." [.button "OK" .plain (some .closeAlert)] else .spacer) ]

def probesView (m : Model) : Html Msg :=
  .screen "Probes" none
    [ .list
      [ .section "Capabilities" "Each button asks the shell; the answer is logged below."
          (probes.zipIdx.map fun ((l, _, _), i) => .button l .plain (some (.probe i)))
      , .section "Log" "Newest first, with system events." (m.log.map (fun s => .text s .caption)) ] ]

def view (m : Model) : Html Msg :=
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

def perform (c : Cmd) (fx : Effects Host) : IO Unit :=
  match c with
  | .ticker => discard <| IO.asTask do
      repeat
        IO.sleep 1000
        fx.post .tick
  | .auth => fx.cap "auth" (Json.mkObj [("reason", "Prove native capabilities work")]) fun j =>
      .authed ((j.getObjValAs? Bool "ok").toOption.getD false) ((j.getObjValAs? String "error").toOption.getD "")
  | .echo text => discard <| IO.asTask do
      let r ← try echoOnce 48334 text catch e => pure s!"failed: {e}"
      fx.post (.echoed r)
  | .probe l n a => fx.cap n a (.probed l)
  | .selftest => do
      -- a headless check for runs nobody clicks through (`NATIVEDEMO_SELFTEST=1` in the launch
      -- environment): the TCP echo and every probe in order, each answer printed to stdout and logged
      let some _ ← IO.getEnv "NATIVEDEMO_SELFTEST" | pure ()
      discard <| IO.asTask do
        let out ← IO.getStdout
        let say (s : String) : IO Unit := do out.putStrLn s!"selftest: {s}"; out.flush
        let r ← try echoOnce 48335 "selftest" catch e => pure s!"failed: {e}"
        say s!"TCP echo: {r}"
        fx.post (.echoed r)
        for (l, n, a) in probes do
          let j ← IO.wait (← fx.ask n a)
          say s!"{l}: {j.compress}"
          fx.post (.probed l j)
        say "done"

def app : Native.App Model Msg Cmd Host :=
  { init := { count := 0, ticks := 0, ticking := false, log := [] }, update, view, cmds, host := Msg.host, perform, boot := [.selftest],
    -- every system event but the scene phase is logged (the Probes tab shows bgtask launches and expirations)
    system := fun j => if (j.getObjVal? "scene").isOk then none else some (.system j) }

initialize Native.register app

end NativeDemo
