import Lean.Data.Json
import ElmLean.Cmd

/-! # Send: Winnow's Send review flow as an ElmLean app with commands

The single-signature send of the Winnow wallet (`Sources/WinnowApp/SendView.swift` and
`AppModel.previewSend` / `AppModel.send(preview:)`): type an address and an amount in sats, pick a fee
priority, review the payment, approve it, and the wallet signs and broadcasts it.

Everything the wallet does is a command for the host (`Cmd`), which runs it against Winnow's
WalletCore and answers with a `HostMsg`:

* `preview` asks for a draft of the payment: address decoding, fee resolution, coin selection
  (Winnow's `SendPreview`). The host answers `previewReady d` or `previewFailed`.
* `sign d` asks the host to authenticate the owner and build and sign the transaction for draft `d`
  (Winnow's `buildSend`, which rebuilds from scratch). The host answers with a summary of what it
  built (`signed s`) or `signFailed`. The signatures stay on the host.
* `broadcast` hands the signed transaction to the network. This app issues it only when the summary
  of what was signed matches the approved draft exactly (`authorizes`, Winnow's
  `SendPreview.authorizes`, here in proven Lean instead of Swift).

Written in the subset `elmgen` translates: no recursion, no `where`, no equality on types with
`String` fields (comparisons are spelled out field by field). -/

namespace Send
open ElmLean

/-- Winnow's fee priorities (`FeePolicy.Priority`). -/
inductive Priority where
  | low
  | medium
  | high
  deriving Repr, DecidableEq, Inhabited, Lean.ToJson, Lean.FromJson

/-- What the user typed on the form. The amount is text: the host parses it, and the app checks
that the draft's amount is the number typed. -/
structure Entry where
  destination : String
  amount : String
  priority : Priority
  deriving Repr, DecidableEq, Inhabited, Lean.ToJson, Lean.FromJson

/-- One transaction output: its value in sats and its output script in hex. -/
structure Out where
  value : Nat
  script : String
  deriving Repr, DecidableEq, Inhabited, Lean.ToJson, Lean.FromJson

/-- A draft the host computed for a form: Winnow's `SendPreview` for the wallet path. The payment
is one output of `amount` sats to `script`, the host's decoding of `destination`. -/
structure Draft where
  /-- The number of the `preview` command this answers. -/
  id : Nat
  /-- The form it was computed for. -/
  form : Entry
  /-- The normalized address the payment goes to (shown on review). -/
  destination : String
  /-- Its output script, hex (the host's decoding of `destination`). -/
  script : String
  amount : Nat
  fee : Nat
  /-- The fee rate in thousandths of a sat per vbyte, which the host rebuilds with. -/
  feeRateMilli : Nat
  /-- The fee rate as the host shows it, e.g. "5 sat/vB". -/
  feeRateText : String
  /-- The change output back to the wallet, if any. -/
  change : Option Out
  /-- The coins spent, as "txid:vout". -/
  inputs : List String
  deriving Repr, Inhabited, Lean.ToJson, Lean.FromJson

/-- What the host reports about the transaction it built and signed for a draft, read from the
signed transaction itself. -/
structure Signed where
  draftId : Nat
  fee : Nat
  changeAmount : Option Nat
  outputs : List Out
  inputs : List String
  txid : String
  /-- The signed transaction, hex. -/
  raw : String
  deriving Repr, Inhabited, Lean.ToJson, Lean.FromJson

/-- Which screen the flow is on. -/
inductive Screen where
  | form
  /-- Waiting for the draft of `preview` command number `id`. -/
  | previewing (id : Nat)
  | review (d : Draft)
  /-- The user approved `d`; waiting for authentication and the signature. -/
  | signing (d : Draft)
  /-- Signed and matching `d`; waiting for the network. -/
  | broadcasting (d : Draft) (txid : String)
  | sent (d : Draft) (txid : String)
  | failed (reason : String)
  deriving Repr, Inhabited

structure Model where
  form : Entry
  screen : Screen
  /-- The number the next `preview` command gets. -/
  nextId : Nat
  /-- What the host last said about the wallet, e.g. "500000 sats available". -/
  balance : String
  deriving Repr, Inhabited

/-- What the host can tell the app. -/
inductive HostMsg where
  /-- Unsolicited: the wallet's balance, as text. -/
  | balance (text : String)
  | previewReady (d : Draft)
  | previewFailed (id : Nat) (reason : String)
  | signed (s : Signed)
  | signFailed (id : Nat) (reason : String)
  | broadcasted (id : Nat) (txid : String)
  | broadcastFailed (id : Nat) (reason : String)
  deriving Repr, Inhabited, Lean.ToJson, Lean.FromJson

inductive Msg where
  | setDestination (s : String)
  | setAmount (s : String)
  | setPriority (p : Priority)
  /-- "Review payment". -/
  | review
  /-- "Send payment" on the review screen. -/
  | approve
  /-- "Edit payment": back to the form, keeping what was typed. -/
  | edit
  /-- "New payment" after a send: an empty form. -/
  | restart
  /-- A host answer (`CmdApp.host`). -/
  | host (h : HostMsg)
  deriving Repr, Inhabited

/-- What the host is asked to do. -/
inductive Cmd where
  /-- Draft a payment for this form; the draft must carry `id`. -/
  | preview (id : Nat) (form : Entry)
  /-- Authenticate the owner, then build and sign the transaction for exactly this draft. -/
  | sign (d : Draft)
  /-- Broadcast this signed transaction, built for draft `id`. -/
  | broadcast (id : Nat) (raw : String)
  deriving Repr, Inhabited, Lean.ToJson, Lean.FromJson

def Entry.empty : Entry := ⟨"", "", .medium⟩

def Model.init : Model := ⟨Entry.empty, .form, 0, ""⟩

/-- `s.trimAscii.copy`, the one `String.Slice` shape the translator understands. -/
def trim (s : String) : String := s.trimAscii.copy

def sameForm (a b : Entry) : Bool :=
  a.destination == b.destination && a.amount == b.amount && a.priority == b.priority

/-- The draft answers the form the user has: same inputs, the amount is the number typed (in its
plain decimal spelling) and the address is the one typed (trimmed). -/
def matchesForm (f : Entry) (d : Draft) : Bool :=
  sameForm d.form f && toString d.amount == trim f.amount && d.destination == trim f.destination

def canReview (f : Entry) : Bool := !(trim f.destination).isEmpty && !(trim f.amount).isEmpty

def sameOut (a b : Out) : Bool := a.value == b.value && a.script == b.script

def countOut (o : Out) (xs : List Out) : Nat := (xs.filter (fun x => sameOut x o)).length

/-- The two lists hold the same outputs, counted with multiplicity, in any order. -/
def sameOuts (xs ys : List Out) : Bool :=
  xs.all (fun o => countOut o xs == countOut o ys) && ys.all (fun o => countOut o xs == countOut o ys)

def countStr (s : String) (xs : List String) : Nat := (xs.filter (fun x => x == s)).length

/-- The two lists hold the same strings, counted with multiplicity, in any order. -/
def sameStrs (xs ys : List String) : Bool :=
  xs.all (fun s => countStr s xs == countStr s ys) && ys.all (fun s => countStr s xs == countStr s ys)

/-- The outputs a transaction for `d` must have: the payment, then the change if any. -/
def expectedOutputs (d : Draft) : List Out :=
  match d.change with
  | some c => [⟨d.amount, d.script⟩, c]
  | none => [⟨d.amount, d.script⟩]

def changeAmountOf (d : Draft) : Option Nat :=
  match d.change with
  | some c => some c.value
  | none => none

/-- Winnow's `SendPreview.authorizes`: the signed transaction is the reviewed one. Same draft, same
fee, same change amount, the same coins, and exactly the reviewed outputs, nothing more (order is
free: Winnow puts the change at a random position). -/
def authorizes (d : Draft) (s : Signed) : Bool :=
  s.draftId == d.id && s.fee == d.fee && s.changeAmount == changeAmountOf d &&
    sameStrs s.inputs d.inputs && sameOuts s.outputs (expectedOutputs d)

/-- Winnow's `feeProportionWarning` rule: the fee is at least half the amount. -/
def feeHeavy (d : Draft) : Bool := if d.amount ≤ d.fee + d.fee then true else false

/-- Typing changes the form; on a screen that shows a draft or waits for one, it also goes back to
the form, so no draft outlives the inputs it was made for. While a payment is being signed or sent
the form is frozen. -/
def edited (m : Model) (f : Entry) : Model :=
  match m.screen with
  | .form => { m with form := f }
  | .previewing _ => { m with form := f, screen := .form }
  | .review _ => { m with form := f, screen := .form }
  | .failed _ => { m with form := f, screen := .form }
  | .signing _ => m
  | .broadcasting _ _ => m
  | .sent _ _ => m

def onHost (h : HostMsg) (m : Model) : Model :=
  match h with
  | .balance t => { m with balance := t }
  | .previewReady d =>
    match m.screen with
    | .previewing id =>
      if d.id = id then
        if matchesForm m.form d then { m with screen := .review d }
        else { m with screen := .failed "The wallet's draft does not match what you typed. Check the amount (digits only) and the address." }
      else m
    | _ => m
  | .previewFailed id reason =>
    match m.screen with
    | .previewing id' => if id = id' then { m with screen := .failed reason } else m
    | _ => m
  | .signed s =>
    match m.screen with
    | .signing d =>
      if s.draftId = d.id then
        if authorizes d s then { m with screen := .broadcasting d s.txid }
        else { m with screen := .failed "The signed transaction does not match the reviewed payment. Nothing was sent." }
      else m
    | _ => m
  | .signFailed id reason =>
    match m.screen with
    | .signing d => if id = d.id then { m with screen := .failed reason } else m
    | _ => m
  | .broadcasted id txid =>
    match m.screen with
    | .broadcasting d _ => if id = d.id then { m with screen := .sent d txid } else m
    | _ => m
  | .broadcastFailed id reason =>
    match m.screen with
    | .broadcasting d _ => if id = d.id then { m with screen := .failed reason } else m
    | _ => m

def update : Msg → Model → Model
  | .setDestination s, m => edited m { m.form with destination := s }
  | .setAmount s, m => edited m { m.form with amount := s }
  | .setPriority p, m => edited m { m.form with priority := p }
  | .review, m =>
    match m.screen with
    | .form => if canReview m.form then { m with screen := .previewing m.nextId, nextId := m.nextId + 1 } else m
    | _ => m
  | .approve, m =>
    match m.screen with
    | .review d => { m with screen := .signing d }
    | _ => m
  | .edit, m =>
    match m.screen with
    | .review _ => { m with screen := .form }
    | .failed _ => { m with screen := .form }
    | _ => m
  | .restart, m =>
    match m.screen with
    | .sent _ _ => { m with form := Entry.empty, screen := .form }
    | _ => m
  | .host h, m => onHost h m

/-- The commands of `update msg m`, from the same pre-state. -/
def cmds : Msg → Model → List Cmd
  | .review, m =>
    match m.screen with
    | .form => if canReview m.form then [.preview m.nextId m.form] else []
    | _ => []
  | .approve, m =>
    match m.screen with
    | .review d => [.sign d]
    | _ => []
  | .host (.signed s), m =>
    match m.screen with
    | .signing d => if s.draftId = d.id ∧ authorizes d s then [.broadcast d.id s.raw] else []
    | _ => []
  | _, _ => []

/-- A label and a value on one line. -/
def line (label value : String) : Html Msg :=
  .row [.text label .caption, .spacer, .text value .body]

def sats (n : Nat) : String := s!"{n} sats"

def changeText (d : Draft) : String :=
  match d.change with
  | some c => sats c.value
  | none => "none"

/-- What the review screen and every later screen show about a draft. -/
def summary (d : Draft) : Html Msg :=
  .col [ .text "To" .caption
       , .text d.destination .body
       , line "Amount" (sats d.amount)
       , line "Network fee" (sats d.fee)
       , line "Total" (sats (d.amount + d.fee))
       , line "Fee rate" d.feeRateText
       , line "Change back" (changeText d)
       , line "Coins spent" s!"{d.inputs.length}" ]

def priorityButton (f : Entry) (p : Priority) (label : String) : Html Msg :=
  .button label (if f.priority = p then .primary else .plain) (some (.setPriority p))

/-- The form; `waiting` while a preview is on its way. -/
def formView (m : Model) (waiting : Bool) : Html Msg :=
  .col [ .text "Send" .title
       , .text m.balance .caption
       , .field "Address" m.form.destination .setDestination none
       , .field "Amount in sats" m.form.amount .setAmount none
       , .row [ priorityButton m.form .low "Low", priorityButton m.form .medium "Medium"
              , priorityButton m.form .high "High" ]
       , .button "Review payment" .primary (if !waiting ∧ canReview m.form then some .review else none)
       , .text (if waiting then "Preparing the payment…" else "") .caption ]

def feeWarning (d : Draft) : String :=
  if feeHeavy d then s!"The fee is at least half of what you are sending: {sats d.fee} to send {sats d.amount}." else ""

/-- Paths: [0] title · [1] the draft (`summary`) · [2] fee warning · [3] Send payment · [4] Edit payment. -/
def reviewView (d : Draft) : Html Msg :=
  .col [ .text "Review payment" .title
       , summary d
       , .text (feeWarning d) .caption
       , .button "Send payment" .primary (some .approve)
       , .button "Edit payment" .plain (some .edit) ]

def view (m : Model) : Html Msg :=
  match m.screen with
  | .form => formView m false
  | .previewing _ => formView m true
  | .review d => reviewView d
  | .signing d => .col [.text "Approve with Face ID" .title, summary d, .text "Signing…" .caption]
  | .broadcasting d txid => .col [.text "Sending" .title, summary d, .text "Transaction" .caption, .text txid .body]
  | .sent d txid =>
    .col [ .text "Payment sent" .title, summary d, .text "Transaction" .caption, .text txid .body
         , .button "New payment" .primary (some .restart) ]
  | .failed reason =>
    .col [ .text "Payment not sent" .title, .text reason .body
         , .button "Edit payment" .plain (some .edit) ]

/-- The app value: what the oracle serves and what the generator reads. -/
def app : CmdApp Model Msg Cmd HostMsg :=
  { init := Model.init, update := update, view := view, cmds := cmds, host := Msg.host }

end Send
