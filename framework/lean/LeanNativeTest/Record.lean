import LeanNative.Native
import LeanNative.TagDeriving

/-! # The record a run keeps: tags, and what `Native.runtime` writes

`deriving LeanNative.Tag` on nested message types (a field of a tagged type, an `Except`, an `Option`), and
`Native.runtime` with a record file: the messages `update` took (a user event's and a host answer's), the commands
`perform` was given, a capability's answers and the failed one among them, and the identifiers the views showed.
-/

namespace LeanNativeTest.Record
open LeanNative LeanNative.Native Lean

inductive Pane where
  | list
  | detail (n : Nat)

inductive Host where
  | loaded (r : Except String Nat)
  | renamed (error : Option String)
  | asked (answer : Json)

inductive Msg where
  | tap
  | pane (p : Pane)
  | host (h : Host)

inductive Cmd where
  | load
  | ask
  deriving ToJson

deriving instance LeanNative.Tag for Pane, Host, Msg, Cmd

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}" else IO.println s!"FAIL {name}"; failures.modify (· + 1)

structure Model where
  taps : Nat := 0
  loaded : Option Nat := none

def update : Msg → Model → Model
  | .tap, m => { m with taps := m.taps + 1 }
  | .host (.loaded (.ok n)), m => { m with loaded := some n }
  | _, m => m

def cmds : Msg → Model → List Cmd
  | .tap, _ => [.load, .ask]
  | _, _ => []

def view (m : Model) : Html Msg :=
  .col [.identified "count" (.text s!"taps {m.taps}" .body), .button "Tap" .plain (some .tap),
        if m.loaded.isSome then .identified "loaded" (.text "loaded" .body) else .text "" .body]

def tags : IO Unit := do
  check "a constructor without a tagged field is its name" (Tag.tag Msg.tap == "tap")
  check "a tagged field follows after a dot" (Tag.tag (Msg.pane (.detail 3)) == "pane.detail")
  check "through two levels, to an Except" (Tag.tag (Msg.host (.loaded (.error "no"))) == "host.loaded.error")
  check "an Option" (Tag.tag (Msg.host (.renamed none)) == "host.renamed.none")
  check "an untagged field is not looked into" (Tag.tag (Msg.host (.asked Json.null)) == "host.asked")
  check "all is every tag, in constructor order" (Tag.all (α := Msg) ==
    #["tap", "pane.list", "pane.detail", "host.loaded.error", "host.loaded.ok", "host.renamed.none",
      "host.renamed.some", "host.asked"])

def runtime : IO Unit := do
  let dir ← IO.FS.createTempDir
  let file := dir / "record.json"
  let fx ← IO.mkRef (none : Option (Effects Host))
  let app : Native.App Model Msg Cmd Host :=
    { init := {}, update, view, cmds, host := Msg.host
      perform := fun c e => do
        fx.set (some e)
        match c with
        | .load => e.post (.loaded (.ok 5))
        | .ask => e.cap "keychain.get" Json.null fun j => .asked j
      tagging := .derived }
  let rt ← Native.runtime app (record := some file)
  discard <| rt.start
  check "the record is there from the start" (← file.pathExists)
  -- a tap: its message, its two commands, a host answer queued, a capability asked
  discard <| rt.event "{\"seq\":0,\"path\":[1],\"event\":{\"k\":\"click\"}}"
  discard <| rt.drain
  rt.capResult "{\"id\":0,\"result\":{\"error\":\"no such item\"}}"
  discard <| rt.drain
  let t := Tally.ofJson ((Json.parse (← IO.FS.readFile file)).toOption.getD Json.null)
  check "the tap's message" (t.msgs.getD "tap" 0 == 1)
  check "the host answers, by tag" (t.msgs.getD "host.loaded.ok" 0 == 1 && t.msgs.getD "host.asked" 0 == 1)
  check "the commands" (t.cmds.getD "load" 0 == 1 && t.cmds.getD "ask" 0 == 1)
  check "the capability's answer, and that it failed" (t.caps.getD "keychain.get" 0 == 1 && t.capFailures.getD "keychain.get" 0 == 1)
  check "the identifiers the views showed" (t.ids.contains "count" && t.ids.contains "loaded")
  check "every tag the app has" (t.allMsgs.size == 8 && t.allCmds == #["load", "ask"])
  check "what never came" (Tally.never t.allMsgs t.msgs == #["pane.list", "pane.detail", "host.loaded.error",
    "host.renamed.none", "host.renamed.some"])
  check "a failed answer: an error, ok false, a status that is not 0" (capFailed (Json.mkObj [("error", "x")]) &&
    capFailed (Json.mkObj [("ok", false)]) && capFailed (Json.mkObj [("status", (-25308 : Int))]) &&
    !capFailed (Json.mkObj [("ok", true), ("status", (0 : Int))]) && !capFailed (Json.mkObj [("hex", "00")]))
  check "a delta is what came since the last read" ((t.sub t).msgs.isEmpty && ((t.add t).msgs.getD "tap" 0 == 2))
  IO.FS.removeDirAll dir

end LeanNativeTest.Record

def main : IO UInt32 := do
  LeanNativeTest.Record.tags
  LeanNativeTest.Record.runtime
  let n ← LeanNativeTest.Record.failures.get
  IO.println (if n == 0 then "record: all passed" else s!"record: {n} failed")
  return if n == 0 then 0 else 1
