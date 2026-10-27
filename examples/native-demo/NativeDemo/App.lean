import Std.Async.TCP
import ElmLean.Native

/-! # A native-mode demo: the pieces Winnow needs, in one screen

* `update`/`view`/`cmds` as in any ElmLean app;
* a command run by a Lean task that answers every second (`tick`);
* a command that asks the shell for an iOS capability (`auth`: Face ID or the passcode);
* a command that talks TCP through Lean's own libuv sockets (an echo server and client in-process). -/

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
  | host (h : Host)

inductive Cmd where
  | ticker
  | auth
  | echo (text : String)
  deriving ToJson

def note (m : Model) (s : String) : Model := { m with log := (s :: m.log).take 5 }

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
  | .host .tick, m => { m with ticks := m.ticks + 1 }
  | .host (.authed ok d), m => note m (if ok then s!"authenticated {d}" else s!"not authenticated: {d}")
  | .host (.echoed r), m => note m s!"TCP echo: {r}"

def cmds : Msg → Model → List Cmd
  | .startTicks, m => if m.ticking then [] else [.ticker]
  | .authenticate, _ => [.auth]
  | .echo, m => [.echo s!"ping {m.count}"]
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

def view (m : Model) : Html Msg :=
  .tabs ["Demo", "Widgets"] ["sparkles", "slider.horizontal.3"] m.tab Msg.tab
    [if m.tab == 0 then .screen "Native mode" none [demoView m] else widgets m]

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

def app : Native.App Model Msg Cmd Host :=
  { init := { count := 0, ticks := 0, ticking := false, log := [] }, update, view, cmds, host := Msg.host, perform }

initialize Native.register app

end NativeDemo
