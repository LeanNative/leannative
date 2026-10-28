import ElmShell.Grammar

/-!
# ElmShell.Check: the table against the Lean side of the protocol

* every `Wire` constructor has a row (`kindTag_mem`), every row's sample prints (`Wire.toJson`) with
  exactly the row's keys, each of the JSON kind the row decodes, and the row's tag;
* `identified` is no row: every sample, identified, prints as itself plus a string `id` (which the shell
  decodes on any node, `idKey`);
* `decorated` is no row either: every sample, decorated, prints as itself plus a `decor` object with the
  shell's decor fields (`decoratedProblems`), and no row has a field named `id` or `decor`;
* the string enums list every constructor (`*_complete`), so their Swift raw values are the
  Lean printer's strings;
* every `Event` constructor has a row (`eventName_mem`), and the JSON the shell sends for each row is
  parsed back by `Event.fromJson?` into that event.

The theorems are checked by the kernel; the rest is `problems`, which the build evaluates (`#guard`)
and `elmshell` checks again before it writes anything.
-/

namespace ElmShell.Check
open Lean ElmLean

def tableTags : List String :=
  ["text", "col", "row", "button", "field", "toggle", "divider", "spacer", "input", "list", "section", "labeled",
   "screen", "toolbar", "tabs", "sheet", "alert", "picker", "progress", "icon", "qr", "share", "link", "page",
   "empty", "disclosure", "stepper"]

def kindTag : Wire → String
  | .text .. => "text" | .col .. => "col" | .row .. => "row" | .button .. => "button" | .field .. => "field"
  | .toggle .. => "toggle" | .divider => "divider" | .spacer => "spacer" | .input .. => "input" | .list .. => "list"
  | .section .. => "section" | .labeled .. => "labeled" | .screen .. => "screen" | .toolbar .. => "toolbar"
  | .tabs .. => "tabs" | .sheet .. => "sheet" | .alert .. => "alert" | .picker .. => "picker"
  | .progress .. => "progress" | .icon .. => "icon" | .qr .. => "qr" | .share .. => "share" | .link .. => "link"
  | .page .. => "page" | .empty .. => "empty" | .disclosure .. => "disclosure" | .stepper .. => "stepper"
  | .identified _ w => kindTag w
  | .decorated _ w => kindTag w

theorem kindTag_mem (w : Wire) : kindTag w ∈ tableTags := by
  cases w with
  | identified _ w => simpa [kindTag] using kindTag_mem w
  | decorated _ w => simpa [kindTag] using kindTag_mem w
  | _ => simp [kindTag, tableTags]

theorem styles_complete (x : TextStyle) : x ∈ allStyles := by cases x <;> simp [allStyles]
theorem roles_complete (x : ButtonRole) : x ∈ allRoles := by cases x <;> simp [allRoles]
theorem tones_complete (x : Tone) : x ∈ allTones := by cases x <;> simp [allTones]
theorem inputKinds_complete (x : InputKind) : x ∈ allInputKinds := by cases x <;> simp [allInputKinds]

/-- One node of every kind, with a child wherever it can have one. -/
def samples : List Wire :=
  let k := [Wire.divider]
  [ .text "t" .caption, .col k, .row k, .button "b" .primary false, .field "p" "v" true, .toggle "l" true, .divider,
    .spacer, .input .secure "l" "p" "v" true, .list k, .section "h" "f" k, .labeled "l" "v", .screen "t" true k true,
    .toolbar k, .tabs ["a"] ["i"] 1 k, .sheet "t" true k, .alert "t" "m" k, .picker "l" ["o"] 0, .progress "l",
    .icon "n", .qr "q", .share "l" "t" true, .link "l" "u", .page "p", .empty "t" "i" "m" k, .disclosure "t" true k,
    .stepper "l" 1 0 2 "d" ]

def eventNames : List String := ["click", "submit", "dismiss", "input", "toggle", "select"]

def eventName : Event → String
  | .click => "click" | .submit => "submit" | .dismiss => "dismiss" | .input _ => "input"
  | .toggle _ => "toggle" | .select _ => "select"

theorem eventName_mem (e : Event) : eventName e ∈ eventNames := by cases e <;> simp [eventName, eventNames]

/-- Each row's event and the `value` the shell would send with it. -/
def eventSamples : List (Event × Option Json) :=
  [ (.click, none), (.submit, none), (.dismiss, none), (.input "x", some (.str "x")), (.toggle true, some (.bool true)),
    (.select 3, some (toJson (3 : Nat))) ]

def jsonKindOk : FTy → Json → Bool
  | .str, .str _ => true
  | .bool _, .bool _ => true
  | .int, .num _ => true
  | .strs, .arr xs => xs.all (fun | .str _ => true | _ => false)
  | .enum t _, .str v => ((stringEnums.find? (·.1 == t)).map (·.2.contains v)).getD false
  | .kids, .arr _ => true
  | _, _ => false

def objKeys : Json → List String
  | .obj kvs => kvs.toList.map (·.1)
  | _ => []

def nodeProblems (w : Wire) : List String :=
  let tag := kindTag w
  let j := w.toJson
  match nodes.find? (·.tag == tag) with
  | none => [s!"no row for `{tag}`"]
  | some k =>
    let keys := (objKeys j).filter (· != "t")
    let want := k.fields.map (·.key)
    (if (j.getObjValAs? String "t").toOption != some tag then [s!"`{tag}`: Wire.toJson prints another tag"] else []) ++
    (if keys.all want.contains && want.all keys.contains && keys.length == want.length then []
     else [s!"`{tag}`: the wire keys are {keys}, the row has {want}"]) ++
    k.fields.filterMap fun f => match j.getObjVal? f.key with
      | .ok v => if jsonKindOk f.ty v then none else some s!"`{tag}.{f.key}`: {v.compress} is not what the row decodes"
      | .error _ => some s!"`{tag}.{f.key}`: absent from Wire.toJson"

/-- `identified`: the node's own object plus `"id"`, a string. -/
def identifiedProblems (w : Wire) : List String :=
  let tag := kindTag w
  match w.toJson, (Wire.identified "x" w).toJson with
  | .obj plain, j@(.obj kvs) =>
    (if (j.getObjValAs? String idKey).toOption == some "x" then [] else [s!"identified `{tag}`: no string `{idKey}`"]) ++
    (if kvs.toList.map (·.1) == ((plain.insert idKey (.str "x")).toList.map (·.1))
        && plain.toList.all (fun (k, v) => (j.getObjVal? k).toOption == some v) then []
     else [s!"identified `{tag}`: not the node's own object plus `{idKey}`"])
  | _, _ => [s!"identified `{tag}`: not an object"]

/-- `decorated`: the node's own object plus `"decor"`, an object with exactly `decorFields`' keys, each of
the kind the shell decodes. -/
def decoratedProblems (w : Wire) : List String :=
  let tag := kindTag w
  let d : Decor := { tone := .positive, mono := true, badge := true, centered := true, symbol := "s", chevron := true }
  match w.toJson, (Wire.decorated d w).toJson with
  | .obj plain, j@(.obj kvs) =>
    (if kvs.toList.map (·.1) == ((plain.insert decorKey .null).toList.map (·.1))
        && plain.toList.all (fun (k, v) => (j.getObjVal? k).toOption == some v) then []
     else [s!"decorated `{tag}`: not the node's own object plus `{decorKey}`"]) ++
    (match j.getObjVal? decorKey with
     | .ok dj =>
       let keys := objKeys dj
       let want := decorFields.map (·.key)
       (if keys.all want.contains && want.all keys.contains && keys.length == want.length then []
        else [s!"decorated `{tag}`: the decor keys are {keys}, the shell has {want}"]) ++
       decorFields.filterMap fun f => match dj.getObjVal? f.key with
         | .ok v => if jsonKindOk f.ty v then none else some s!"decor.{f.key}: {v.compress} is not what the shell decodes"
         | .error _ => some s!"decor.{f.key}: absent from Decor.toJson"
     | .error _ => [s!"decorated `{tag}`: no `{decorKey}`"])
  | _, _ => [s!"decorated `{tag}`: not an object"]

/-- No row uses the keys any node may carry. -/
def reservedProblems : List String :=
  nodes.filterMap fun k =>
    if k.fields.any (fun f => f.key == idKey || f.key == decorKey) then some s!"`{k.tag}` has a field `{idKey}` or `{decorKey}`" else none

def problems : List String :=
  (if nodes.map (·.tag) == tableTags then [] else ["the grammar table's tags are not `tableTags`"]) ++
  (if samples.map kindTag == tableTags then [] else ["`samples` does not have one node per row, in order"]) ++
  samples.flatMap nodeProblems ++
  samples.flatMap identifiedProblems ++
  samples.flatMap decoratedProblems ++ reservedProblems ++
  (if events.map (·.1) == eventNames then [] else ["the event table's names are not `eventNames`"]) ++
  eventSamples.filterMap fun (e, v) =>
    let name := eventName e
    let j := Json.mkObj ([("k", .str name)] ++ (v.map fun v => [("value", v)]).getD [])
    let typed := (events.find? (·.1 == name)).map (·.2.isSome) == some v.isSome
    match Event.fromJson? j with
    | .ok e' => if e' == e && typed then none else some s!"event `{name}`: the shell's JSON is not that event"
    | .error err => some s!"event `{name}`: {err}"

#guard problems == []

end ElmShell.Check
