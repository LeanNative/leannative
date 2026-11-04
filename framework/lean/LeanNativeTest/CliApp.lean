import LeanNative.CmdCli

/-! # A small app on each stdin/stdout shell (`make check`)

`cli-test-app` runs `list` on `LeanNative.Cli.main` and `cmdcli-test-app` runs `saving` (the same screen
with commands) on `LeanNative.CmdCli.main`, so the Lean shells themselves are what `protocol_test.py` and
`selftest` drive, not only `fake_cli.py`. The view is what the harness reads (rows, buttons, a field and
toggles) with a disabled button and a field without a submit at launch for its converse cases, and a
count drawn with chained decorations (`tone` then `mono`), which cross the wire as one `"decor"`. -/

namespace LeanNativeTest.CliApp
open LeanNative Lean

structure Model where
  count : Nat := 0
  draft : String := ""
  /-- each item's label (trimmed, never empty) and whether it is done -/
  items : List (String × Bool) := []
  /-- the host's last answer (`saving` only): how many items it says it holds -/
  saved : Option Nat := none
  deriving Inhabited

inductive Host where
  | saved (count : Nat)
  | failed (why : String)
  deriving FromJson, ToJson

inductive Msg where
  | inc
  | reset
  | draft (s : String)
  | add
  | set (i : Nat) (done : Bool)
  | remove (i : Nat)
  | host (h : Host)

inductive Cmd where
  | save (labels : List String)
  deriving ToJson

def trimmed (s : String) : String := s.trimAscii.toString

def update : Msg → Model → Model
  | .inc, m => { m with count := m.count + 1 }
  | .reset, m => { m with count := 0 }
  | .draft s, m => { m with draft := s }
  | .add, m => if (trimmed m.draft).isEmpty then m else { m with items := m.items ++ [(trimmed m.draft, false)], draft := "" }
  | .set i b, m => { m with items := m.items.modify i fun (l, _) => (l, b) }
  | .remove i, m => { m with items := m.items.eraseIdx i }
  | .host (.saved n), m => { m with saved := some n }
  | .host (.failed _), m => { m with saved := none }

def view (m : Model) : Html Msg :=
  .col ([ .text "Items" .title
        , .row [ .identified "count" (Html.mono (Html.tone .positive (.text s!"Count: {m.count}" .body)))
               , .spacer
               , .button "+1" .primary (some .inc)
               , .button "Reset" .destructive (if m.count == 0 then none else some .reset) ]
        , .field "New item" m.draft Msg.draft (if (trimmed m.draft).isEmpty then none else some .add) ]
        ++ m.items.mapIdx (fun i (l, done) =>
             .row [.toggle l done (Msg.set i), .spacer, .button "Delete" .destructive (some (.remove i))])
        ++ (match m.saved with
            | some n => [Html.badge (.text s!"saved {n}" .caption)]
            | none => []))

/-- The labels the host keeps: saved whenever a message changes them. -/
def cmds (msg : Msg) (m : Model) : List Cmd :=
  let after := (update msg m).items
  if after.map (·.1) == m.items.map (·.1) then [] else [.save (after.map (·.1))]

def list : App Model Msg := { init := {}, update, view }

def saving : CmdApp Model Msg Cmd Host := { list with cmds, host := Msg.host }

/-- What `update` keeps true: every label is trimmed and not empty. -/
def labelsTrimmed (m : Model) : Bool := m.items.all fun (l, _) => !l.isEmpty && trimmed l == l

def samples (m : Model) : List Host := [.saved m.items.length, .failed "offline"]

/-- The command rule, over every message in this model: a `save` carries exactly the labels `update`
leaves, and only a message that changes them asks for one. -/
def saveRule (m : Model) : Bool :=
  let msgs := [Msg.inc, .reset, .draft "x", .add] ++ (List.range (m.items.length + 1)).flatMap
    (fun i => [Msg.set i true, .remove i]) ++ (samples m).map Msg.host
  labelsTrimmed m && msgs.all fun msg =>
    let labels := (update msg m).items.map (·.1)
    match cmds msg m with
    | [] => labels == m.items.map (·.1)
    | [.save ls] => ls == labels && labels != m.items.map (·.1)
    | _ => false

def listOptions : Cli.Options Model := { check := labelsTrimmed, maxSteps := 1500 }

def savingOptions : CmdCli.Options Model Host := { cli := { check := saveRule, maxSteps := 1500 }, samples }

end LeanNativeTest.CliApp
