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
    (chevron : Bool := false) (swipe : String := "none") (selected : Bool := false) (menu : Bool := false)
    (key : String := "") (pointer : String := "") (callout : Bool := false) : Json :=
  Json.mkObj [("tone", Json.str tone), ("mono", Json.bool mono), ("badge", Json.bool badge),
              ("centered", Json.bool centered), ("symbol", Json.str symbol), ("chevron", Json.bool chevron),
              ("swipe", Json.str swipe), ("selected", Json.bool selected), ("menu", Json.bool menu),
              ("key", Json.str key), ("pointer", Json.str pointer), ("callout", Json.bool callout)]

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

/-- A split's columns are its children: a click in one is dispatched at the child's place, going back from one
(a narrow window) is that screen's `onBack`, and the chosen row says so in its decoration. -/
def columns : IO Unit := do
  let inbox : Html Nat := Html.chosen true (.identified "inbox" (.button "Inbox" .plain (some 1)))
  let split : Html Nat := .split 1
    [ .screen "Boxes" none [.list [.section "" "" [inbox]]],
      .screen "Inbox" (some 9) [.button "A message" .plain (some 2)] ]
  check "a click in the first column is its button's" (split.dispatch [0, 0, 0, 0] .click == some 1)
  check "a click in the second column is its button's" (split.dispatch [1, 0] .click == some 2)
  check "going back from the second column is its screen's" (split.dispatch [1] .dismiss == some 9)
  check "the first column has nothing to go back to" (split.dispatch [0] .dismiss == none)
  check "and the wire advertises the same" (split.toWire.advertises [1] .dismiss && !split.toWire.advertises [0] .dismiss)
  check "the split's JSON names the column a narrow window shows"
    ((split.toWire.toJson.getObjValAs? Nat "shown").toOption == some 1
      && (split.toWire.toJson.getObjValAs? String "t").toOption == some "split"
      && ((split.toWire.toJson.getObjValAs? (Array Json) "c").toOption.map (·.size)) == some 2)
  same "the chosen row's JSON: the button's own keys, its id and one decor" inbox
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Inbox"), ("role", Json.str "plain"),
      ("enabled", Json.bool true), ("id", Json.str "inbox"), ("decor", decorJson (selected := true))])
  let other : Html Nat := Html.chosen false (.button "Archive" .plain (some 1))
  check "a row that is not chosen has no decoration" ((other.toWire.toJson.getObjVal? "decor").toOption == none)

/-- A row's swipe action is a button with one more decoration: its click and its place in the tree are a
button's (a journey presses it by its identifier; a phone swipes the row). -/
def swipes : IO Unit := do
  let done : Html Nat := Html.swipe .trailing (Html.symbol "checkmark" (.identified "done" (.button "Done" .primary (some 3))))
  let row : Html Nat := .list [.section "" "" [.col [.text "Maya" .headline, done]]]
  check "a swipe action dispatches its click where the button stands" (row.dispatch [0, 0, 1] .click == some 3)
  check "and the wire advertises it there" (row.toWire.advertises [0, 0, 1] .click)
  same "its JSON: the button's own keys, its id and one decor"  done
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Done"), ("role", Json.str "primary"),
      ("enabled", Json.bool true), ("id", Json.str "done"), ("decor", decorJson (symbol := "checkmark") (swipe := "trailing"))])
  let off : Html Nat := Html.swipe .leading (Html.swipe .trailing (.button "Snooze" .plain none))
  same "the outer edge wins, and a disabled one is still on the wire" off
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Snooze"), ("role", Json.str "plain"),
      ("enabled", Json.bool false), ("decor", decorJson (swipe := "leading"))])

/-- A row's menu item and a key equivalent are decorations too: the node, its click and its place in the tree
are what they were, so a journey presses a menu's button by its identifier and a shell that knows neither field
draws the button. -/
def menusAndKeys : IO Unit := do
  let done : Html Nat := Html.inMenu (Html.swipe .trailing (Html.symbol "checkmark" (.identified "done" (.button "Done" .plain (some 7)))))
  let row : Html Nat := .col [.text "A message" .body, done, Html.inMenu (.button "Report" .destructive (some 8))]
  check "a click on a menu's button is its message" (row.dispatch [1] .click == some 7 && row.dispatch [2] .click == some 8)
  check "and the wire advertises it" (row.toWire.advertises [1] .click)
  same "a button that is a swipe action and a menu item: one decor" done
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Done"), ("role", Json.str "plain"),
      ("enabled", Json.bool true), ("id", Json.str "done"), ("decor", decorJson (symbol := "checkmark") (swipe := "trailing") (menu := true))])
  let sync : Html Nat := Html.key "cmd+r" (.identified "sync" (.button "Sync" .plain (some 3)))
  same "a button with a key: the button's own keys, its id and one decor" sync
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Sync"), ("role", Json.str "plain"),
      ("enabled", Json.bool true), ("id", Json.str "sync"), ("decor", decorJson (key := "cmd+r"))])
  check "a key changes nothing a click does" (sync.dispatch [] .click == some 3)
  -- a row's click with a modifier held is a button of the row, with its own click
  let pick : Html Nat := Html.onClickWith "cmd" (.identified "pick" (.button "Pick" .plain (some 4)))
  same "a button for a modifier's click: the button's own keys, its id and one decor" pick
    (Json.mkObj [("t", Json.str "button"), ("label", Json.str "Pick"), ("role", Json.str "plain"),
      ("enabled", Json.bool true), ("id", Json.str "pick"), ("decor", decorJson (pointer := "cmd"))])
  check "a modifier's click is the button's own click" (pick.dispatch [] .click == some 4)
  -- on a screen the key is its pull to refresh, the screen's own click; on an input it is the cursor, no event
  let screen : Html Nat := Html.key "cmd+shift+n" (.screen "Inbox" none [Html.key "cmd+f" (.input .plain "" "Search" "" (fun _ => 1) none)] (onRefresh := some 5))
  check "a screen with a key: its click is its refresh" (screen.dispatch [] .click == some 5)
  check "the screen's JSON has the key" (((screen.toWire.toJson.getObjVal? "decor").toOption.bind (·.getObjValAs? String "key" |>.toOption)) == some "cmd+shift+n")
  let both : Html Nat := Html.key "cmd+k" (Html.key "cmd+j" (Html.inMenu (.button "B" .plain (some 1))))
  check "an outer key replaces an inner one, and keeps the rest"
    ((both.toWire.toJson.getObjVal? "decor").toOption == some (decorJson (menu := true) (key := "cmd+k")))

def callouts : IO Unit := do
  let action : Html Nat := .identified "retry" (.button "Retry" .primary (some 7))
  let content := [label, action]
  let panel := Html.tone .warning (.identified "warning" (Html.callout content))
  check "callout merges through an identifier without changing the children"
    (match panel.toWire with
     | .identified "warning" (.decorated d (.col kids)) =>
       d == { tone := .warning, callout := true } &&
       kids.map Wire.toJson == (Html.col content).toWire.children.map Wire.toJson
     | _ => false)
  check "callout flag reaches the native shell"
    ((panel.toWire.toJson.getObjVal? "decor" >>= (·.getObjValAs? Bool "callout")).toOption == some true)
  check "a default outer decoration preserves a callout" (({ callout := true } : Decor).merge {}).callout
  check "a callout preserves its button handler"
    ((Html.callout content).dispatch [1] .click == some 7)
  check "a disabled callout button stays disabled"
    ((Html.callout [.button "Retry" .primary none] : Html Nat).dispatch [0] .click == none)

def main : IO UInt32 := do
  composition
  controls
  swipes
  columns
  menusAndKeys
  callouts
  let n ← failures.get
  IO.println (if n == 0 then "html: all passed" else s!"html: {n} FAILED")
  return if n == 0 then 0 else 1
