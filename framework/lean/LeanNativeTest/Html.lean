import LeanNative.Json

/-! # Decorations as the shell receives them

`Html.tone`, `mono`, `badge`, `centered`, `symbol` and `navigates` chain (`Html.badge (Html.tone .warning t)`, as
apps write them), and a chain is one decoration: `Html.decor` merges into the one already there (`Decor.merge`),
through an identifier too. Each case is checked on `Html.toWire`'s JSON, what the CLI and the native shell
are handed: one `"decor"` object on the node, with every field the chain set. -/

open LeanNative Lean

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}" else IO.println s!"FAIL {name}"; failures.modify (· + 1)

def wire (h : Html Nat) : Json := h.toWire.toJson

/-- The node's `"decor"` on the wire, with any field not given its default. -/
def decorJson (tone : String := "standard") (mono badge centered : Bool := false) (symbol : String := "")
    (chevron : Bool := false) : Json :=
  Json.mkObj [("tone", Json.str tone), ("mono", Json.bool mono), ("badge", Json.bool badge),
              ("centered", Json.bool centered), ("symbol", Json.str symbol), ("chevron", Json.bool chevron)]

def label : Html Nat := .text "1,000 sats" .body

/-- The text node's own JSON with `extra` keys set. -/
def labelWith (extra : List (String × Json)) : Json :=
  extra.foldl (fun j (k, v) => j.setObjVal! k v) (wire label)

def same (name : String) (h : Html Nat) (expected : Json) : IO Unit := do
  let got := wire h
  check name (got.compress == expected.compress)
  unless got.compress == expected.compress do
    IO.println s!"       got      {got.compress}\n       expected {expected.compress}"

/-- No decorated node directly inside another: a chain is one decoration. -/
partial def flat : Wire → Bool
  | .decorated _ (.decorated ..) => false
  | .decorated _ w | .identified _ w => flat w
  | w => w.children.all flat

def composition : IO Unit := do
  same "one helper is one decor" (Html.tone .positive label) (labelWith [("decor", decorJson "positive")])
  same "tone then mono: one decor with both" (Html.mono (Html.tone .positive label))
    (labelWith [("decor", decorJson "positive" (mono := true))])
  same "badge over tone (an app's warning badge)" (Html.badge (Html.tone .warning label))
    (labelWith [("decor", decorJson "warning" (badge := true))])
  same "the outer tone wins" (Html.tone .negative (Html.tone .positive label)) (labelWith [("decor", decorJson "negative")])
  same "a standard tone outside leaves the inner one" (Html.tone .standard (Html.tone .positive label))
    (labelWith [("decor", decorJson "positive")])
  same "the outer symbol wins" (Html.symbol "star" (Html.symbol "bolt" label)) (labelWith [("decor", decorJson (symbol := "star"))])
  same "an empty symbol outside leaves the inner one" (Html.symbol "" (Html.symbol "bolt" label))
    (labelWith [("decor", decorJson (symbol := "bolt"))])
  let all := Html.navigates (Html.symbol "qrcode" (Html.centered (Html.badge (Html.mono (Html.tone .tint label)))))
  same "all six helpers chained: every field, one decor" all
    (labelWith [("decor", decorJson "tint" true true true "qrcode" true)])
  check "the chain's wire has no decoration inside a decoration" (flat all.toWire)
  -- a set flag stays set whichever side sets it
  same "mono, then tone over it" (Html.tone .secondary (Html.mono label)) (labelWith [("decor", decorJson "secondary" (mono := true))])
  -- through an identifier: the decoration is merged under it, the id stays on the node
  let identified := Html.badge (Html.identified "fee" (Html.tone .warning label))
  same "through an identifier: one decor beside the id" identified
    (labelWith [("decor", decorJson "warning" (badge := true)), ("id", Json.str "fee")])
  check "the identified chain has no decoration inside a decoration" (flat identified.toWire)
  let tonedThenIdentified := Html.mono (Html.identified "fee" (Html.tone .warning label))
  check "identified: the merged decoration is the identifier's child"
    (match tonedThenIdentified.toWire with
     | .identified "fee" (.decorated d (.text ..)) => d == { tone := .warning, mono := true }
     | _ => false)
  -- inside a tree: each node's own chain, not its neighbours'
  same "a row of two chains"
    (.row [Html.badge (Html.tone .positive label), Html.mono label])
    (Json.mkObj [("t", Json.str "row"), ("c", Json.arr #[labelWith [("decor", decorJson "positive" (badge := true))],
      labelWith [("decor", decorJson (mono := true))]])])

/-- Decorations change how a control looks, never what it does or advertises. -/
def controls : IO Unit := do
  let delete : Html Nat := Html.navigates (Html.tone .negative (.button "Delete" .destructive (some 7)))
  check "a decorated button still dispatches its click" (delete.dispatch [] .click == some 7)
  check "and the wire still advertises it" (delete.toWire.advertises [] .click)
  let disabled : Html Nat := Html.symbol "lock" (Html.tone .secondary (.button "Send" .primary none))
  check "a decorated disabled button dispatches nothing" (disabled.dispatch [] .click == none)
  check "and the wire does not advertise it" (!disabled.toWire.advertises [] .click)
  same "the button's JSON: its own keys and one decor" delete
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Delete"), ("role", Json.str "destructive"),
      ("enabled", Json.bool true), ("decor", decorJson "negative" (chevron := true))])

def main : IO UInt32 := do
  composition
  controls
  let n ← failures.get
  IO.println (if n == 0 then "html: all passed" else s!"html: {n} FAILED")
  return if n == 0 then 0 else 1
