/-!
# ElmGen.SwiftAST

The intermediate tree between the Lean terms and the two printers (`ElmGen.Emit` prints
`Generated.swift`, `ElmGen.Screen` prints the SwiftUI screen).  It is a small, expression-level
Swift: every node prints to Swift source that a reviewer can compare with the Lean definition.

Two constructors carry structure the screen printer needs and would otherwise have to recover by
string matching: `html` (an `ElmLean.Html` constructor application) and `helper` (a reference to a
translated app definition, which the screen prints as `App.helper(...)` or, for `Html`-returning
helpers, as a method of the screen struct).
-/

namespace ElmGen

mutual
inductive SExpr where
  | raw (s : String)                                            -- identifier / literal
  | call (f : String) (args : List (Option String × SExpr))     -- f(label: a, b)
  | member (e : SExpr) (name : String)                          -- e.name
  | method (e : SExpr) (name : String) (args : List (Option String × SExpr))
  | binop (op : String) (a b : SExpr)
  | unop (op : String) (a : SExpr)
  | ternary (c t e : SExpr)
  | array (xs : List SExpr)
  | closure (params : List (String × String)) (ret : String) (body : List SStmt)
  | iife (ret : String) (body : List SStmt)                     -- ({ () -> ret in ... })()
  | emptyArray (elemTy : String)                                -- [elemTy]()
  /-- `Html<msgTy>.ctor(args)`; the labels are the Lean binder names for the labelled constructors. -/
  | html (ctor : String) (msgTy : String) (args : List (Option String × SExpr))
  /-- A translated app definition: `f` (static var) or `f(args)`; `retHtml` says whether it returns `Html`. -/
  | helper (f : String) (args : List SExpr) (retHtml : Bool)
inductive SStmt where
  | letS (n : String) (v : SExpr)
  | ret (e : SExpr)
  | ite (c : SExpr) (t e : List SStmt)
  | switch (scrut : SExpr) (cases : List (String × List SStmt))
end

/-- How the printers qualify references to app definitions: `"Self."` inside the app enum itself
(so a local binder that happens to carry a helper's short name can never shadow the static helper),
`"TodoApp."` from the screen struct. -/
structure PrintCfg where
  helperPrefix : String := "Self."

def SExpr.isAtom : SExpr → Bool
  | .raw .. | .call .. | .member .. | .method .. | .array .. | .closure .. | .html .. | .helper .. | .emptyArray .. => true
  | _ => false

def pad (n : Nat) : String := "".pushn ' ' n

/-- Html constructor trees and Html-returning helper calls: arrays of these print one element per line. -/
def SExpr.isView : SExpr → Bool
  | .html .. => true
  | .helper _ _ true => true
  | _ => false

mutual
/-- Print an expression; `ind` is the indentation of the line it sits on (multi-line bodies indent from it). -/
partial def SExpr.print (cfg : PrintCfg) (ind : Nat) : SExpr → String
  | .raw s => s
  | .call f args => s!"{f}({printArgs cfg ind args})"
  | .member e n => s!"{paren cfg ind e}.{n}"
  | .method e n args => s!"{paren cfg ind e}.{n}({printArgs cfg ind args})"
  | .binop op a b => s!"({a.print cfg ind} {op} {b.print cfg ind})"
  | .unop op a => s!"{op}{paren cfg ind a}"
  | .ternary c t e => s!"({c.print cfg ind} ? {t.print cfg ind} : {e.print cfg ind})"
  | .array xs =>
    if xs.length > 1 && xs.any SExpr.isView then
      "[\n" ++ ",\n".intercalate (xs.map fun x => pad (ind + 4) ++ x.print cfg (ind + 4)) ++ "\n" ++ pad ind ++ "]"
    else "[" ++ ", ".intercalate (xs.map (·.print cfg ind)) ++ "]"
  | .emptyArray t => s!"[{t}]()"
  | .closure ps ret body =>
    let params := ", ".intercalate (ps.map fun (n, t) => s!"{n}: {t}")
    match body with
    | [.ret e] => s!"\{ ({params}) -> {ret} in {e.print cfg ind} }"
    | _ => s!"\{ ({params}) -> {ret} in\n{printStmts cfg (ind + 4) body}\n{pad ind}}"
  | .iife ret body => s!"(\{ () -> {ret} in\n{printStmts cfg (ind + 4) body}\n{pad ind}})()"
  | .html ctor msgTy args =>
    if args.isEmpty then s!"Html<{msgTy}>.{ctor}" else s!"Html<{msgTy}>.{ctor}({printArgs cfg ind args})"
  | .helper f args _ =>
    let f := cfg.helperPrefix ++ f
    if args.isEmpty then f else s!"{f}({", ".intercalate (args.map (·.print cfg ind))})"
partial def paren (cfg : PrintCfg) (ind : Nat) (e : SExpr) : String :=
  if e.isAtom then e.print cfg ind else s!"({e.print cfg ind})"
partial def printArgs (cfg : PrintCfg) (ind : Nat) (args : List (Option String × SExpr)) : String :=
  ", ".intercalate (args.map fun (l, a) => match l with | some l => s!"{l}: {a.print cfg ind}" | none => a.print cfg ind)
partial def printStmts (cfg : PrintCfg) (ind : Nat) (ss : List SStmt) : String :=
  "\n".intercalate (ss.map fun s => s.print cfg ind)
partial def SStmt.print (cfg : PrintCfg) (ind : Nat) (s : SStmt) : String :=
  match s with
  | .letS n v => s!"{pad ind}let {n} = {v.print cfg ind}"
  | .ret e => s!"{pad ind}return {e.print cfg ind}"
  | .ite c t e =>
    s!"{pad ind}if {c.print cfg ind} \{\n{printStmts cfg (ind + 4) t}\n{pad ind}} else \{\n{printStmts cfg (ind + 4) e}\n{pad ind}}"
  | .switch sc cases =>
    let cs := cases.map fun (p, body) => s!"{pad ind}case {p}:\n{printStmts cfg (ind + 4) body}"
    s!"{pad ind}switch {sc.print cfg ind} \{\n{"\n".intercalate cs}\n{pad ind}}"
end

/-- A Lean doc comment as Swift `///` lines at indentation `ind`. -/
def docLines (ind : Nat) (doc : Option String) : List String :=
  match doc with
  | none => []
  | some d =>
    let ls := (d.splitOn "\n").map fun l => l.trimAscii.copy
    let ls := ls.reverse.dropWhile (·.isEmpty) |>.reverse.dropWhile (·.isEmpty)
    ls.map fun l => if l.isEmpty then s!"{pad ind}///" else s!"{pad ind}/// {l}"

end ElmGen
