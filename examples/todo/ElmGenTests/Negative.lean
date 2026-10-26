import ElmGen
import Todo.App
/-!
# elmgen corpus: loud rejections and accepted probes

Run from `examples/todo/` after `lake build`:  `lake env lean ElmGenTests/Negative.lean`
(or `make corpus`). It lives with the Todo example because its probes reuse Todo's model as a fixture.  Every case is a throwaway `App` defined
below (never part of the library).  A rejection must name the construct (the expected substring),
an acceptance must produce Swift containing the expected text.  Any mismatch is a `throwError`, so
`lean` exits non-zero.

Sources: the spike's NegTest.lean, the judges' correctness probes (probes.lean.part, streq, tree) and
maintainability probes (common.lean: Counter app, `where`, Bool literal pattern, nested structure
pattern, String.toUpper, role-name collision), plus the fixes of this phase (List patterns, Option
patterns, Equatable only with DecidableEq, reserved Swift names).
-/
set_option linter.unusedVariables false
open Lean Meta

namespace Todo
open ElmLean
-- ---- spike NegTest.lean ----
def sumIds (m : Model) : Nat := m.todos.foldl (fun acc t => acc + t.id) 0
def negApp1 : App Model Msg := ⟨Model.init, update, fun m => .text (toString (sumIds m)) .body⟩
def count : List Todo → Nat | [] => 0 | _ :: ts => count ts + 1
def negApp2 : App Model Msg := ⟨Model.init, update, fun m => .text (toString (count m.todos)) .body⟩
def firstDone : Msg → Bool | .setDone _ true => true | _ => false
def negApp3 : App Model Msg := ⟨Model.init, update, fun m => .text (toString (firstDone .add)) .body⟩
def negApp4 : App Model Msg := ⟨Model.init, update, fun m => .text (toString (m.nextId - 1)) .body⟩
def negApp5 : App Model Msg := ⟨Model.init, update, fun m => .text (if m.todos = [] then "e" else "n") .body⟩
def okApp : App Model Msg := ⟨Model.init, update, fun m => .text (if m.draft = "x" then "yes" else "no") .body⟩
def tupleMatch (m : Model) (msg : Msg) : Nat :=
  match m.filter, msg with
  | .all, .add => 1
  | .active, .setDraft s => s.length
  | _, _ => 0
def okApp2 : App Model Msg := ⟨Model.init, update, fun m =>
  .text (let n := remaining m; toString (n + tupleMatch m .add)) .body⟩
-- ---- judges' correctness probes ----
def pFoldl (xs : List Nat) : Nat := xs.foldl (· + ·) 0
def pFoldlApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (pFoldl [m.nextId])) .body⟩
def pOptMatch (o : Option Nat) : Nat := match o with | some n => n | none => 0
def pOptMatchApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (pOptMatch (some m.nextId))) .body⟩
def pDite (m : Model) : Nat := if h : m.nextId = 0 then 0 else 1
def pDiteApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (pDite m)) .body⟩
def pRec : List Nat → Nat | [] => 0 | _ :: t => 1 + pRec t
def pRecApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (pRec [m.nextId])) .body⟩
def pLetExpr (m : Model) : Html Msg := .text (let n := remaining m; s!"{n}") .body
def pLetExprApp : App Model Msg := ⟨Model.init, update, pLetExpr⟩
def pWhere (m : Model) : Nat := helper m.nextId
where helper (n : Nat) : Nat := n + 1
def pStrApp (m : Model) : String := m.draft ++ "!"
def pNatLt (m : Model) : Bool := m.nextId < 5
def pStrLen (m : Model) : Nat := m.draft.length
def pBoolOps (m : Model) : Bool := (m.draft.isEmpty && !m.todos.isEmpty) || m.nextId == 0
def pStrEq (m : Model) : Bool := if m.draft = "a" then true else false
def pView2 (m : Model) : Html Msg := .col
  [ .field "d" m.draft .setDraft (some .add)
  , .text s!"{pWhere m}" .body
  , .text (pStrApp m) .body
  , .text (if pNatLt m then "t" else "f") .body
  , .text s!"{pStrLen m}" .body
  , .text (if pBoolOps m then "t" else "f") .body
  , .text (if pStrEq m then "t" else "f") .body ]
def pApp2 : App Model Msg := ⟨Model.init, update, pView2⟩
def pNested : Option (Option Nat) := some none
def pNestedView (m : Model) : Html Msg := .text (if pNested = none then "none" else "some") .body
def pNestedApp : App Model Msg := ⟨Model.init, update, pNestedView⟩
def pStrEq2 (m : Model) : Bool := if m.draft = "é" then true else false
def pView6 (m : Model) : Html Msg := .col [ .field "d" m.draft .setDraft none, .text (if pStrEq2 m then "eq" else "ne") .body ]
def pApp6 : App Model Msg := ⟨Model.init, update, pView6⟩
inductive Tree where
  | leaf
  | node (l : Tree) (r : Tree)
def isLeaf : Tree → Bool | .leaf => true | .node _ _ => false
def treeApp : App Model Msg := ⟨Model.init, update, fun m => .text (if isLeaf (.node .leaf .leaf) then "leaf" else "node") .body⟩
def size : Tree → Nat
  | .leaf => 0
  | .node l r => size l + size r + 1
def sizeApp : App Model Msg := ⟨Model.init, update, fun m => .text s!"{size (.node .leaf .leaf) + m.nextId}" .body⟩
-- ---- judges' maintainability probes ----
def updateW (msg : Msg) (m : Model) : Model :=
  match msg with
  | .add => addTodo m
  | .setDraft s => { m with draft := s }
  | _ => m
where
  addTodo (m : Model) : Model :=
    let title := trimTitle m.draft
    if title.isEmpty then m
    else { m with todos := ⟨m.nextId, title, false⟩ :: m.todos, draft := "", nextId := m.nextId + 1 }
def whereApp : App Model Msg := ⟨Model.init, updateW, view⟩
def isDoneMsg : Msg → Bool
  | .setDone _ true => true
  | _ => false
def boolPatView (m : Model) : Html Msg :=
  .col [ .text (if isDoneMsg (.setDone 0 false) then "WRONG" else "ok") .body
       , .button "Add" .primary (some .add) ]
def boolPatApp : App Model Msg := ⟨Model.init, update, boolPatView⟩
def nestedView (m : Model) : Html Msg :=
  match m with
  | ⟨[], _, _, _⟩ => .text "empty" .body
  | ⟨t :: _, _, _, _⟩ => .text t.title .body
def nestedApp : App Model Msg := ⟨Model.init, update, nestedView⟩
def shoutView (m : Model) : Html Msg := .text m.draft.toUpper .body
def shoutApp : App Model Msg := ⟨Model.init, update, shoutView⟩
def updateC (msg : Msg) (m : Model) : Model :=
  match msg with
  | .clearDone => m
  | _ => update msg m
def collideApp : App Model Msg := ⟨Model.init, updateC, view⟩
-- ---- this phase: List patterns, Prod patterns, reserved names, Float ----
def headTitle : List Todo → String | [] => "" | t :: _ => t.title
def headApp : App Model Msg := ⟨Model.init, update, fun m => .text (headTitle m.todos) .body⟩
def isSingleton : List Nat → Bool | [_] => true | _ => false
def singletonApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (isSingleton [m.nextId])) .body⟩
def fstOf (p : Nat × Nat) : Nat := match p with | (a, _) => a
def prodApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (fstOf (m.nextId, 1))) .body⟩
inductive View where | a | b
def viewKind (m : Model) : View := if m.nextId = 0 then .a else .b
def reservedApp : App Model Msg := ⟨Model.init, update, fun m => .text (match viewKind m with | .a => "a" | .b => "b") .body⟩
def useFloat (m : Model) : Nat := if (1.0 : Float) < 2.0 then m.nextId else 0
def floatApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (useFloat m)) .body⟩
def cmpMsg (m : Model) : Bool := decide (Msg.add = Msg.clearDone)
def msgEqApp : App Model Msg := ⟨Model.init, update, fun m => .text (toString (cmpMsg m)) .body⟩
end Todo

namespace ElmLean.ProbeCounter
structure Model where
  count : Nat
  flag : Bool
  deriving Repr, Inhabited
inductive Msg where
  | inc
  | reset
  | setFlag (b : Bool)
  deriving Repr, DecidableEq
def Model.init : Model := ⟨0, false⟩
def update : Msg → Model → Model
  | .inc, m => { m with count := m.count + 1 }
  | .reset, m => { m with count := 0 }
  | .setFlag b, m => { m with flag := b }
def view (m : Model) : Html Msg :=
  .col [ .text s!"Count: {m.count}" .title
       , .button "Increment" .primary (some .inc)
       , .button "Reset" .destructive (if m.count = 0 then none else some .reset)
       , .toggle "Flag" m.flag (fun b => .setFlag b) ]
def counterApp : App Model Msg := ⟨Model.init, update, view⟩
end ElmLean.ProbeCounter

namespace ElmGenTests
open ElmGen

def run (app : Name) (swiftName : String) : MetaM (Except String Output) := do
  try pure (.ok (← generateAll app swiftName (defaultScreenName swiftName)))
  catch e => pure (.error (← e.toMessageData.toString))

def contains (hay needle : String) : Bool := (hay.splitOn needle).length > 1

def expectReject (app : Name) (needle : String) : MetaM Unit := do
  match ← run app "ProbeApp" with
  | .ok _ => throwError "FAIL {app}: expected a rejection mentioning `{needle}`, but it was ACCEPTED"
  | .error msg =>
    unless contains msg needle do
      throwError "FAIL {app}: rejected, but the message does not mention `{needle}`:\n{msg}"
    IO.println s!"[reject ok] {app}\n    {msg}"

def expectAccept (app : Name) (needles : List String) (screenNeedles : List String := [])
    (swiftName : String := "ProbeApp") : MetaM Unit := do
  match ← run app swiftName with
  | .error msg => throwError "FAIL {app}: expected acceptance, but it was rejected:\n{msg}"
  | .ok o =>
    for n in needles do
      unless contains o.generated n do throwError "FAIL {app}: Generated.swift lacks `{n}`:\n{o.generated}"
    for n in screenNeedles do
      unless contains o.screen n do throwError "FAIL {app}: the screen lacks `{n}`:\n{o.screen}"
    IO.println s!"[accept ok] {app} ({o.summary})"

#eval show MetaM Unit from do
  -- loud rejections, each naming the construct
  expectReject ``Todo.negApp1 "List.foldl"
  expectReject ``Todo.negApp2 "recursive definition"
  expectAccept ``Todo.negApp4 ["max((", " - 1), 0)"]   -- Nat subtraction is saturating in Lean: printed as max(a - b, 0)
  expectReject ``Todo.negApp5 "equality (==) on type `List Todo.Todo`"
  expectReject ``Todo.pFoldlApp "List.foldl"
  expectReject ``Todo.pDiteApp "dite"
  expectReject ``Todo.pRecApp "recursive definition"
  expectReject ``Todo.sizeApp "recursive definition"
  expectReject ``Todo.nestedApp "structure pattern"
  expectReject ``Todo.shoutApp "String.toUpper"
  expectReject ``Todo.collideApp "produced by both"
  expectReject ``Todo.singletonApp "nested List pattern"
  expectReject ``Todo.prodApp "non-app inductive"   -- the tuple constructor is reached before the pattern; both are loud
  expectReject ``Todo.reservedApp "collides with a name the Swift runtime"
  expectReject ``Todo.floatApp "comparison on a non-Nat type"
  expectReject ``Todo.msgEqApp "equality (==) on type `Todo.Msg`"
  -- accepted probes, with the Swift the fixes must produce
  expectAccept ``Todo.negApp3 ["case Msg.setDone(_, true):", "case _:"]
  expectAccept ``Todo.okApp [".draft.unicodeScalars.elementsEqual(\"x\".unicodeScalars)"]
  expectAccept ``Todo.okApp2 ["switch (", "case (Filter.all, Msg.add):", "case (_, _):", "() -> String in"]
  expectAccept ``Todo.pOptMatchApp ["case Optional<Int>.some(let n):", "case Optional<Int>.none:"]
  expectAccept ``Todo.pLetExprApp ["let n = Self.remaining(", "return String(n)"]
  expectAccept ``Todo.pApp2
    ["static func pWhere_helper(_ n: Int) -> Int", "pWhere_helper(m.nextId)", "(m.draft + \"!\")", "(m.nextId < 5)",
     "m.draft.unicodeScalars.count", "!m.todos.isEmpty", "(m.nextId == 0)"]
    ["ElmField(placeholder: \"d\", value: m.draft"]
  expectAccept ``Todo.pNestedApp ["static var pNested: Int??", "Optional<Int?>.some(Optional<Int>.none)", "(Self.pNested == Optional<Int?>.none)"]
  expectAccept ``Todo.pApp6 ["m.draft.unicodeScalars.elementsEqual(\"é\".unicodeScalars)"]
  expectAccept ``Todo.treeApp ["indirect enum Tree {", "case node(Tree, Tree)", "case Tree.node(_, _):"]
  expectAccept ``Todo.whereApp ["static func updateW_addTodo(_ m: Model) -> Model", "updateW_addTodo(", "static func update(_ a0: Msg, _ a1: Model) -> Model"]
  expectAccept ``Todo.boolPatApp ["case Msg.setDone(_, true):", "(Self.isDoneMsg(Msg.setDone(0, false)) ? \"WRONG\" : \"ok\")"]
    ["ElmText((TodoApp.isDoneMsg(Msg.setDone(0, false)) ? \"WRONG\" : \"ok\"), TextStyle.body)"] (swiftName := "TodoApp")
  expectAccept ``Todo.headApp ["if x.isEmpty {", "let head = x[0]", "return head.title"]   -- the matcher names the field `head`
  expectAccept ``Todo.app
    ["enum Filter: Equatable {", "enum Msg {", "struct Todo {", "struct Model {", "/// Set a todo's done flag",
     "/// Paths: [0] title"]
    ["struct TodoScreen: View", "let store: Store<TodoApp>", "ForEach(Array(TodoApp.visible(m).enumerated()), id: \\.offset) { _, t in",
     "@ViewBuilder func todoRow(_ t: Todo) -> some View", "RoleButton(\"Clear done\", role: ButtonRole.destructive"] (swiftName := "TodoApp")
  expectAccept ``ElmLean.ProbeCounter.counterApp
    ["struct Model {", "var count: Int", "enum Msg: Equatable {", "case setFlag(Bool)", "Model(count: 0, flag: false)",   -- Bool payload only: exact ==
     "((m.count == 0) ? Optional<Msg>.none : Optional<Msg>.some(Msg.reset))"]
    ["ElmToggle(label: \"Flag\", on: m.flag, onToggle: { (b: Bool) -> Msg in Msg.setFlag(b) }, send: store.send)",
     "ElmText((\"Count: \" + String(m.count)), TextStyle.title)"] (swiftName := "CounterApp")
  IO.println "elmgen corpus OK"

end ElmGenTests
