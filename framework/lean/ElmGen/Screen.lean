import ElmGen.Emit
/-!
# ElmGen.Screen

The SwiftUI screen printer: a second printer over the same intermediate tree.  `view (m : Model) :
Html Msg` becomes `struct <Screen>: View { let store: Store<App>; var body: some View { let m =
store.model; … } }` where every `Html` constructor maps to the element kit (`framework/swift/Elements.swift`)
with the SAME argument expressions plus `send: store.send`, `List.map f` in children position becomes
`ForEach`, `if` in view position becomes a ViewBuilder `if`, Html-returning helpers become
`@ViewBuilder` methods of the screen struct, and every other expression is printed exactly as in
`Generated.swift` with helper calls qualified as `App.helper(...)`.
-/

namespace ElmGen.Screen
open Lean
open ElmGen

/-- Judgment log (state) + failure (named construct). -/
abbrev M := StateT (Array String) (Except String)

def judge (s : String) : M Unit := modify fun js => if js.contains s then js else js.push s
def fail (msg : String) : M α := throw s!"elmgen (screen): {msg}"

structure Cfg where
  appName : String
  print : PrintCfg

def ex (c : Cfg) (ind : Nat) (e : SExpr) : String := e.print c.print ind

def jText := "Html.text s st → ElmText(s, st)"
def jCol := "Html.col xs → VStack(alignment: .leading, spacing: 12) { xs }"
def jRow := "Html.row xs → HStack(spacing: 12) { xs }"
def jButton := "Html.button l r c → RoleButton(l, role: r, msg: c, send: store.send)"
def jField := "Html.field p v f s → ElmField(placeholder: p, value: v, onInput: f, onSubmit: s, send: store.send)"
def jToggle := "Html.toggle l on f → ElmToggle(label: l, on: on, onToggle: f, send: store.send)"
def jDivider := "Html.divider → Divider(); Html.spacer → Spacer()"
def jForEach := "List.map f xs in children position → ForEach(Array(xs.enumerated()), id: \\.offset) { _, x in f x }"
def jIf := "if c then a else b in view position → if c { a } else { b } inside the ViewBuilder"
def jMatchView := "match in view position → switch inside the ViewBuilder"
def jHelperView := "Html-returning helper → @ViewBuilder method of the screen struct (so store is in scope); its calls are plain method calls"
def jHelperValue := "non-Html helper call → App.helper(...) (printed exactly as in Generated.swift)"
def jEmpty := "[] in children position → EmptyView()"
def jGroup := "more than 10 children → chunks of 10 wrapped in Group { } (ViewBuilder arity limit)"
def jAppend := "xs ++ ys in children position → the two child lists one after the other"
def jLet := "let in view position → let inside the ViewBuilder"

def htmlArg (ctor : String) (args : List (Option String × SExpr)) (i : Nat) : M SExpr :=
  match args[i]? with
  | some (_, x) => pure x
  | none => fail s!"Html.{ctor}: missing argument {i}"

/-- Does the expression mention an `Html`-returning helper or Html constructor (i.e. is it a view)? -/
partial def mentionsHtml : SExpr → Bool
  | .html .. => true
  | .helper _ _ true => true
  | .ternary c t e => mentionsHtml c || mentionsHtml t || mentionsHtml e
  | .iife _ body => body.any stmtMentionsHtml
  | _ => false
where
  stmtMentionsHtml : SStmt → Bool
    | .ret e => mentionsHtml e
    | .ite _ t e => t.any stmtMentionsHtml || e.any stmtMentionsHtml
    | .switch _ cs => cs.any fun (_, b) => b.any stmtMentionsHtml
    | .letS _ v => mentionsHtml v

mutual
/-- Lines rendering `e` (of type `Html`) as a View at indentation `ind`. -/
partial def viewExpr (c : Cfg) (ind : Nat) (e : SExpr) : M (List String) := do
  match e with
  | .html ctor _ args =>
    let a := htmlArg ctor args
    match ctor with
    | "text" => judge jText; pure [s!"{pad ind}ElmText({ex c ind (← a 0)}, {ex c ind (← a 1)})"]
    | "col" =>
      judge jCol
      pure ([s!"{pad ind}VStack(alignment: .leading, spacing: 12) \{"] ++ (← viewChildren c (ind + 4) (← a 0)) ++ [s!"{pad ind}}"])
    | "row" =>
      judge jRow
      pure ([s!"{pad ind}HStack(spacing: 12) \{"] ++ (← viewChildren c (ind + 4) (← a 0)) ++ [s!"{pad ind}}"])
    | "button" =>
      judge jButton
      pure [s!"{pad ind}RoleButton({ex c ind (← a 0)}, role: {ex c ind (← a 1)}, msg: {ex c ind (← a 2)}, send: store.send)"]
    | "field" =>
      judge jField
      pure [s!"{pad ind}ElmField(placeholder: {ex c ind (← a 0)}, value: {ex c ind (← a 1)}, onInput: {ex c ind (← a 2)}, onSubmit: {ex c ind (← a 3)}, send: store.send)"]
    | "toggle" =>
      judge jToggle
      pure [s!"{pad ind}ElmToggle(label: {ex c ind (← a 0)}, on: {ex c ind (← a 1)}, onToggle: {ex c ind (← a 2)}, send: store.send)"]
    | "divider" => judge jDivider; pure [s!"{pad ind}Divider()"]
    | "spacer" => judge jDivider; pure [s!"{pad ind}Spacer()"]
    | other => fail s!"Html constructor `{other}` has no element-kit view (add one to Elements.swift and here)"
  | .helper f args true =>
    judge jHelperView
    if args.isEmpty then pure [s!"{pad ind}{f}"]
    else pure [s!"{pad ind}{f}({", ".intercalate (args.map (ex c ind))})"]
  | .ternary cnd t el =>
    judge jIf
    pure ([s!"{pad ind}if {ex c ind cnd} \{"] ++ (← viewExpr c (ind + 4) t) ++ [s!"{pad ind}} else \{"] ++ (← viewExpr c (ind + 4) el) ++ [s!"{pad ind}}"])
  | .iife _ body => viewStmts c ind body
  | .raw s => fail s!"an Html value flows through the variable `{s}` in view position; the screen printer renders constructor trees only"
  | _ => fail s!"unsupported expression in view position: {ex c 0 e}"

/-- Lines rendering a `List Html` expression as the children of a stack. -/
partial def viewChildren (c : Cfg) (ind : Nat) (e : SExpr) : M (List String) := do
  match e with
  | .array xs =>
    if xs.length ≤ 10 then
      let mut out := []
      for x in xs do out := out ++ (← viewExpr c ind x)
      pure out
    else
      judge jGroup
      let mut out := []
      let mut rest := xs
      while !rest.isEmpty do
        let chunk := rest.take 10
        rest := rest.drop 10
        out := out ++ [s!"{pad ind}Group \{"]
        for x in chunk do out := out ++ (← viewExpr c (ind + 4) x)
        out := out ++ [s!"{pad ind}}"]
      pure out
  | .emptyArray _ => judge jEmpty; pure [s!"{pad ind}EmptyView()"]
  | .method xs "map" [(none, f)] =>
    match f with
    | .closure [(x, _)] _ body =>
      judge jForEach
      pure ([s!"{pad ind}ForEach(Array({ex c ind xs}.enumerated()), id: \\.offset) \{ _, {x} in"] ++ (← viewStmts c (ind + 4) body) ++ [s!"{pad ind}}"])
    | _ => fail s!"List.map in children position with a function that is not a lambda: {ex c 0 f}"
  | .binop "+" a b =>
    judge jAppend
    pure ((← viewChildren c ind a) ++ (← viewChildren c ind b))
  | .ternary cnd t el =>
    judge jIf
    pure ([s!"{pad ind}if {ex c ind cnd} \{"] ++ (← viewChildren c (ind + 4) t) ++ [s!"{pad ind}} else \{"] ++ (← viewChildren c (ind + 4) el) ++ [s!"{pad ind}}"])
  | _ => fail s!"unsupported children expression in view position: {ex c 0 e}"

/-- Statements in view position (ViewBuilder rules: `let`, `if`, `switch`; the tail value is the view). -/
partial def viewStmts (c : Cfg) (ind : Nat) (ss : List SStmt) : M (List String) := do
  let mut out : List String := []
  for s in ss do
    match s with
    | .letS n v =>
      judge jLet
      if mentionsHtml v then fail s!"an Html value is bound to the variable `{n}` in view position; only constructor trees are rendered"
      out := out ++ [s!"{pad ind}let {n} = {ex c ind v}"]
    | .ret e => out := out ++ (← viewExpr c ind e)
    | .ite cnd t el =>
      judge jIf
      out := out ++ [s!"{pad ind}if {ex c ind cnd} \{"] ++ (← viewStmts c (ind + 4) t) ++ [s!"{pad ind}} else \{"] ++ (← viewStmts c (ind + 4) el) ++ [s!"{pad ind}}"]
    | .switch sc cases =>
      judge jMatchView
      out := out ++ [s!"{pad ind}switch {ex c ind sc} \{"]
      for (p, body) in cases do
        out := out ++ [s!"{pad ind}case {p}:"] ++ (← viewStmts c (ind + 4) body)
      out := out ++ [s!"{pad ind}}"]
  pure out
end

def screenHeader (r : GenResult) (viewName : Name) : List String :=
  [ s!"// GENERATED by elmgen: the SwiftUI image of `{viewName}` (Lean {Lean.versionString}).",
    s!"// Do not edit: regenerate with `lake exe elmgen --app {r.appConst} --name {r.appName} --screen-name {r.screenName} ...`.",
    "// Every Html constructor of the view is the element-kit view of framework/swift/Elements.swift with the same arguments." ]

/-- The whole screen file and the screen printer's judgments. -/
def render (r : GenResult) : Except String (String × Array String) :=
  let c : Cfg := { appName := r.appName, print := { helperPrefix := r.appName ++ "." } }
  let act : M String := do
    judge jHelperValue
    let all := r.defs ++ r.members
    let some view := all.find? (·.swiftName == "view") | fail "no `view` member was translated"
    let [(mName, _)] := view.params | fail "`view` must take exactly one argument (the model)"
    let mut lines : List String :=
      screenHeader r view.leanName ++ ["", "import SwiftUI", "",
        s!"struct {r.screenName}: View \{", s!"    let store: Store<{r.appName}>", "",
        "    var body: some View {", s!"        let {mName} = store.model"]
    lines := lines ++ (← viewStmts c 8 view.body) ++ ["    }"]
    for d in r.defs do
      if d.retHtml && d.swiftName != "view" then
        judge jHelperView
        let head := if d.params.isEmpty then s!"    @ViewBuilder var {d.swiftName}: some View \{"
          else s!"    @ViewBuilder func {d.swiftName}({", ".intercalate (d.params.map fun (n, t) => s!"_ {n}: {t}")}) -> some View \{"
        lines := lines ++ [""] ++ docLines 4 d.doc ++ [head] ++ (← viewStmts c 8 d.body) ++ ["    }"]
    lines := lines ++ ["}", ""]
    let js ← get
    lines := lines ++ judgmentTrailer "how the view became SwiftUI" js
    pure ("\n".intercalate lines ++ "\n")
  match act.run #[] with
  | .ok (text, js) => .ok (text, js)
  | .error e => .error e

end ElmGen.Screen
