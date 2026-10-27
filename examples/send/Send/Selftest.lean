import ElmLean.CmdCli
import Send.App

/-! TRUSTED SHELL: the Send example's self-test options. `samples` gives plausible host answers in
each model (the lockstep driver feeds them to both CLIs through `{"samples":true}`), including
answers the app must ignore or refuse: a draft for another form, a stale draft, a signed
transaction that does not match. `script` replays a payment and two attacks. -/

namespace Send.Selftest
open ElmLean

/-- A draft for form `f`, as the host would compute it, with `bump` sats added to the amount. -/
def draftFor (id : Nat) (f : Entry) (bump : Nat) : Draft :=
  let amount := ((trim f.amount).toNat?.getD 0) + bump
  { id, form := f, destination := trim f.destination, script := "5120" ++ "ab".pushn 'c' 62,
    amount, fee := 141, feeRateMilli := 1000, feeRateText := "1 sat/vB",
    change := some ⟨500000 - amount - 141, "0014" ++ "".pushn 'd' 40⟩,
    inputs := ["a1".pushn '0' 62 ++ ":0"] }

/-- What the host would report after signing `d`, with the fee off by `feeOff`. -/
def signedFor (d : Draft) (feeOff : Nat) : Signed :=
  { draftId := d.id, fee := d.fee + feeOff, changeAmount := changeAmountOf d,
    outputs := (expectedOutputs d).reverse, inputs := d.inputs,
    txid := "f".pushn '0' 63, raw := "02000000" ++ "".pushn 'e' 40 }

/-- The honest answer is listed three times, so a random walk that picks one sample at a time
mostly makes progress (the lockstep driver picks uniformly). -/
def samples (m : Model) : List HostMsg :=
  match m.screen with
  | .form => [.balance "500000 sats available"]
  | .previewing id =>
    let ok := HostMsg.previewReady (draftFor id m.form 0)
    [ok, ok, ok, .previewReady (draftFor id m.form 1), .previewReady (draftFor (id + 1) m.form 0),
     .previewFailed id "Insufficient funds", .balance "499000 sats available"]
  | .review d => [.signed (signedFor d 0), .previewReady d]
  | .signing d =>
    let ok := HostMsg.signed (signedFor d 0)
    [ok, ok, ok, .signed (signedFor d 1), .signed { signedFor d 0 with draftId := d.id + 1 },
     .signFailed d.id "Face ID failed", .signFailed (d.id + 1) "stale"]
  | .broadcasting d _ =>
    let ok := HostMsg.broadcasted d.id ("f".pushn '0' 63)
    [ok, ok, .broadcastFailed d.id "No peers", .broadcasted (d.id + 1) "x"]
  | _ => [.balance "500000 sats available"]

/-- Runtime mirror of `Send.Inv`. -/
def check (m : Model) : Bool :=
  match m.screen with
  | .review d | .signing d | .broadcasting d _ | .sent d _ => matchesForm m.form d
  | _ => true

def ev (s : Session Model Msg) (p : List Nat) (e : Event) : Input HostMsg := .event ⟨s.seq, p, e⟩

/-- A payment end to end, then an edit that must void a draft, then a lying host. -/
def script : Except String String := do
  let run := fun (s : Session Model Msg) (i : Input HostMsg) => s.step app i
  let s := Session.start app.toApp
  let (s, _, _) := run s (ev s [2] (.input "tb1qexample"))
  let (s, _, _) := run s (ev s [3] (.input "25000"))
  let (s, _, cs) := run s (ev s [5] .click)
  let some (.preview id f) := cs.head? | throw "Review payment did not ask for a preview"
  let (s, _, _) := run s (.host (.previewReady (draftFor id f 0)))
  let .review d := s.model.screen | throw "a matching draft was not shown for review"
  unless d.amount == 25000 do throw "the reviewed amount is not the amount typed"
  let (s1, _, cs) := run s (ev s [3] .click)
  unless cs.any (fun c => match c with | .sign d' => d'.id == d.id | _ => false) do throw "Send payment did not ask to sign the draft"
  let (s2, _, cs) := run s1 (.host (.signed (signedFor d 1)))
  unless cs.isEmpty do throw "a mismatching signed transaction was broadcast"
  let .failed _ := s2.model.screen | throw "a mismatching signed transaction did not fail the payment"
  let (s3, _, cs) := run s1 (.host (.signed (signedFor d 0)))
  unless cs.any (fun c => match c with | .broadcast i _ => i == d.id | _ => false) do throw "a matching signed transaction was not broadcast"
  let (s3, _, _) := run s3 (.host (.broadcasted d.id "t"))
  let .sent _ _ := s3.model.screen | throw "the payment did not reach the sent screen"
  -- editing on the review screen voids the draft, and its late twin is ignored
  let (e1, _, _) := run s (ev s [4] .click)
  let (e1, _, _) := run e1 (ev e1 [3] (.input "26000"))
  let (e1, _, _) := run e1 (.host (.previewReady (draftFor id f 0)))
  let .form := e1.model.screen | throw "a draft for old inputs was shown after an edit"
  pure "payment, refused mismatch, voided draft"

def options : CmdCli.Options Model HostMsg :=
  { cli := { check, script, maxSteps := 3000 }, samples }

end Send.Selftest
