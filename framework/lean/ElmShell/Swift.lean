/-!
# ElmShell.Swift

The Swift that `elmshell` prints, as a tree: declarations, statements and expressions, with leaf
expressions and conditions kept as source text (`raw`). It is to the native shell what
`ElmGen.SwiftAST` is to generated mode, with what a SwiftUI app needs on top: type and member
declarations, trailing closures, modifier chains, `guard`, `for`, `#if`.

The printer lays the tree out at four spaces per level. Short closures, `if`s and `guard`s print on one
line; a modifier chain stays on its base's line while it is short and starts each modifier on its own
line otherwise.
-/

namespace ElmShell

mutual
inductive Expr where
  /-- An identifier, literal or small expression, printed as is. -/
  | raw (s : String)
  /-- A string literal (escaped). -/
  | lit (s : String)
  /-- `f(a, label: b) { … } label: { … }`; with no arguments and a trailing closure, `f { … }`. -/
  | call (f : Expr) (args : List (Option String × Expr)) (trailing : List (Option String × Expr))
  /-- `e.name` -/
  | dot (e : Expr) (name : String)
  /-- `{ head in body }` (`head` empty: no `in`). -/
  | lam (head : String) (body : List Stmt)
  /-- `base.m₁.m₂…`: each modifier prints after a `.`. -/
  | chain (base : Expr) (mods : List Expr)
inductive Stmt where
  | e (x : Expr)
  | letS (lhs : String) (v : Expr)
  | varS (lhs : String) (v : Expr)
  | set (lhs : String) (v : Expr)
  | ret (v : Option Expr)
  /-- `if c₁, c₂ { t } else { el }`; an `el` that is a single `ifS` prints as `else if`. -/
  | ifS (conds : List String) (t : List Stmt) (el : List Stmt)
  | guardS (conds : List String) (el : List Stmt)
  /-- `switch scrut { case p: … }`; the pattern `default` prints as `default:`. -/
  | switchS (scrut : Expr) (cases : List (String × List Stmt))
  /-- `for head { body }` (`head` is `x in xs`, with any `where`). -/
  | forS (head : String) (body : List Stmt)
  | whileS (cond : String) (body : List Stmt)
  | ifdef (cond : String) (t el : List Stmt)
  | deferS (body : List Stmt)
  | comment (s : String)
end

inductive Decl where
  | imp (m : String)
  /-- A `///` doc comment on the declaration that follows. -/
  | doc (text : String) (d : Decl)
  | comment (s : String)
  /-- `head { members }`: a struct, class, enum or extension (`head` may carry attribute lines). -/
  | ty (head : String) (members : List Decl)
  /-- A stored property or constant: `head` or `head = v`. -/
  | prop (head : String) (v : Option Expr)
  /-- A computed property, function or initializer: `head { body }`. -/
  | fn (head : String) (body : List Stmt)
  /-- An enum case declaration (`case a, b` or `case a(String)`). -/
  | caseD (s : String)
  /-- A blank line between members. -/
  | blank

def pad (n : Nat) : String := "".pushn ' ' n

def escape (s : String) : String :=
  s.foldl (fun acc c => match c with
    | '"' => acc ++ "\\\""
    | '\\' => acc ++ "\\\\"
    | '\n' => acc ++ "\\n"
    | c => acc.push c) ""

def oneLine (s : String) : Bool := !s.contains '\n'

/-- The widest line a construct is folded onto. -/
def width : Nat := 110

mutual
partial def Expr.print (ind : Nat) : Expr → String
  | .raw s => s
  | .lit s => "\"" ++ escape s ++ "\""
  | .dot e n => e.print ind ++ "." ++ n
  | .call f args trailing =>
    let a := ", ".intercalate (args.map fun (l, x) => match l with
      | some l => s!"{l}: {x.print ind}"
      | none => x.print ind)
    let head := f.print ind ++ (if args.isEmpty && !trailing.isEmpty then "" else s!"({a})")
    trailing.foldl (fun acc (l, x) => match l with
      | none => acc ++ " " ++ x.print (lastIndent acc ind)
      | some l => acc ++ s!" {l}: " ++ x.print (lastIndent acc ind)) head
  | .lam head body =>
    let open_ := if head.isEmpty then "{" else "{ " ++ head ++ " in"
    let inner := printStmts (ind + 4) body
    match body with
    | [s] =>
      let flat := (s.print 0)
      if oneLine flat && simple s && ind + flat.length + open_.length < width then
        open_ ++ " " ++ flat ++ " }"
      else open_ ++ "\n" ++ inner ++ "\n" ++ pad ind ++ "}"
    | [] => "{}"
    | _ => open_ ++ "\n" ++ inner ++ "\n" ++ pad ind ++ "}"
  | .chain base mods =>
    let b := base.print ind
    let ms := mods.map fun m => "." ++ m.print ind
    let flat := b ++ String.join ms
    if oneLine flat && ind + flat.length < width then flat
    else
      let mind := if oneLine b then ind + 4 else ind
      b ++ String.join (mods.map fun m => "\n" ++ pad mind ++ "." ++ m.print mind)
/-- The indentation of the last line of `s` (a trailing closure's `}` lines up with it). -/
partial def lastIndent (s : String) (ind : Nat) : Nat :=
  match (s.splitOn "\n").getLast? with
  | some l => if (s.splitOn "\n").length > 1 then (l.takeWhile (· == ' ')).copy.length else ind
  | none => ind
/-- Statements that may sit on one line inside braces. -/
partial def simple : Stmt → Bool
  | .e _ | .letS .. | .set .. | .ret _ => true
  | _ => false
partial def printStmts (ind : Nat) (ss : List Stmt) : String :=
  "\n".intercalate (ss.map (·.print ind))
partial def block (ind : Nat) (head : String) (body : List Stmt) : String :=
  let line := pad ind ++ head ++ " {"
  match body with
  | [] => line ++ "}"
  | [s] =>
    let flat := s.print 0
    if oneLine flat && simple s && line.length + flat.length + 3 < width then line ++ " " ++ flat ++ " }"
    else line ++ "\n" ++ printStmts (ind + 4) body ++ "\n" ++ pad ind ++ "}"
  | _ => line ++ "\n" ++ printStmts (ind + 4) body ++ "\n" ++ pad ind ++ "}"
partial def Stmt.print (ind : Nat) : Stmt → String
  | .e x => pad ind ++ x.print ind
  | .letS l v => pad ind ++ s!"let {l} = " ++ v.print ind
  | .varS l v => pad ind ++ s!"var {l} = " ++ v.print ind
  | .set l v => pad ind ++ s!"{l} = " ++ v.print ind
  | .ret none => pad ind ++ "return"
  | .ret (some v) => pad ind ++ "return " ++ v.print ind
  | .ifS cs t el =>
    let head := "if " ++ ", ".intercalate cs
    match el with
    | [] => block ind head t
    | [s] =>
      let tflat := t.map (·.print 0); let eflat := s.print 0
      let oneLiner := t.length == 1 && tflat.all oneLine && t.all simple && oneLine eflat && simple s
      let flat := pad ind ++ head ++ " { " ++ String.join tflat ++ " } else { " ++ eflat ++ " }"
      if oneLiner && flat.length < width then flat
      else match s with
        | .ifS .. =>
          let first := block ind head t
          let rest := (s.print ind).drop ind
          first ++ " else " ++ rest.copy
        | _ => block ind head t ++ " else {\n" ++ printStmts (ind + 4) el ++ "\n" ++ pad ind ++ "}"
    | _ => block ind head t ++ " else {\n" ++ printStmts (ind + 4) el ++ "\n" ++ pad ind ++ "}"
  | .guardS cs el => block ind ("guard " ++ ", ".intercalate cs ++ " else") el
  | .switchS sc cases =>
    let cs := cases.map fun (p, body) =>
      let label := if p == "default" then "default:" else s!"case {p}:"
      match body with
      | [s] =>
        let flat := s.print 0
        if oneLine flat && simple s && ind + label.length + flat.length + 1 < width then
          pad ind ++ label ++ " " ++ flat
        else pad ind ++ label ++ "\n" ++ printStmts (ind + 4) body
      | _ => pad ind ++ label ++ "\n" ++ printStmts (ind + 4) body
    pad ind ++ "switch " ++ sc.print ind ++ " {\n" ++ "\n".intercalate cs ++ "\n" ++ pad ind ++ "}"
  | .forS head body => block ind ("for " ++ head) body
  | .whileS c body => block ind ("while " ++ c) body
  | .ifdef c t el =>
    let e := if el.isEmpty then "" else "\n#else\n" ++ printStmts ind el
    s!"#if {c}\n" ++ printStmts ind t ++ e ++ "\n#endif"
  | .deferS body => block ind "defer" body
  | .comment s => "\n".intercalate ((s.splitOn "\n").map fun l => pad ind ++ "// " ++ l)
end

def docLines (ind : Nat) (text : String) : String :=
  "\n".intercalate ((text.splitOn "\n").map fun l => if l.isEmpty then pad ind ++ "///" else pad ind ++ "/// " ++ l)

def headLines (ind : Nat) (head : String) : String :=
  "\n".intercalate ((head.splitOn "\n").map (pad ind ++ ·))

partial def Decl.print (ind : Nat) : Decl → String
  | .imp m => s!"import {m}"
  | .doc t d => docLines ind t ++ "\n" ++ d.print ind
  | .comment s => "\n".intercalate ((s.splitOn "\n").map fun l => pad ind ++ "// " ++ l)
  | .ty head ms =>
    headLines ind head ++ " {\n" ++ "\n".intercalate (ms.map (·.print (ind + 4))) ++ "\n" ++ pad ind ++ "}"
  | .prop head none => headLines ind head
  | .prop head (some v) => headLines ind head ++ " = " ++ v.print ind
  | .fn head body =>
    let hs := head.splitOn "\n"
    let attrs := hs.dropLast.map (pad ind ++ ·)
    String.join (attrs.map (· ++ "\n")) ++ (block ind (hs.getLast?.getD "") body)
  | .caseD s => pad ind ++ "case " ++ s
  | .blank => ""

/-- A whole file: a header comment, the imports, then the declarations, a blank line apart. -/
def file (header : List String) (decls : List Decl) : String :=
  let imports := decls.filter (fun | .imp _ => true | _ => false)
  let rest := decls.filter (fun | .imp _ => false | _ => true)
  "\n".intercalate (header.map ("// " ++ ·)) ++ "\n" ++
  "\n".intercalate (imports.map (·.print 0)) ++ "\n\n" ++
  "\n\n".intercalate (rest.map (·.print 0)) ++ "\n"

/-! Shorthands for the trees the shell is written in. -/

def r (s : String) : Expr := .raw s
/-- `f(args…)` with unlabelled arguments given as source text. -/
def c (f : String) (args : List String := []) : Expr := .call (.raw f) (args.map fun a => (none, .raw a)) []
/-- `f(args) { head in body }` -/
def cb (f : String) (args : List String) (head : String) (body : List Stmt) : Expr :=
  .call (.raw f) (args.map fun a => (none, .raw a)) [(none, .lam head body)]
/-- A statement that is just source text. -/
def s (src : String) : Stmt := .e (.raw src)
/-- `base` with modifiers given as source text. -/
def m (base : Expr) (mods : List String) : Expr := .chain base (mods.map Expr.raw)

end ElmShell
