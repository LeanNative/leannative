/-!
# LeanNativeShell.ObjC

The Objective-C that `leannative-shell` prints, as a tree of lines: a line is source text, and a block is the
line that opens it, its body (one level deeper) and the line that closes it. An `if … else if … else`
chain, or a method whose block argument is followed by more of the call, is one block with several
heads (`} else {`, `} forControlEvents:…`), each with its own body. The printer indents by four spaces
per level and puts preprocessor lines at the margin.

The tree carries the shell's structure; the grammar-dependent parts of it (node decoding, the renderer's
dispatch, the events, the capabilities) are assembled from the tables in `LeanNativeShell.Grammar` and
`LeanNativeShell.Capabilities`.
-/

namespace LeanNativeShell

inductive Stmt where
  /-- a line of source text -/
  | l (s : String)
  /-- a preprocessor line (`#if`, `#else`, `#endif`), printed at the margin -/
  | pp (s : String)
  | blank
  /-- `head₁ {` body₁ `head₂` body₂ … `close`: each head opens a level, the next head or `close` ends it -/
  | blk (parts : List (String × List Stmt)) (close : String := "}")
  deriving Inhabited

def pad (n : Nat) : String := "".pushn ' ' n

partial def Stmt.lines (ind : Nat) : Stmt → List String
  | .l s => [pad ind ++ s]
  | .pp s => [s]
  | .blank => [""]
  | .blk parts close =>
    parts.flatMap (fun (head, body) => (pad ind ++ head) :: body.flatMap (·.lines (ind + 4))) ++ [pad ind ++ close]

/-- `head {` body `}` -/
def b (head : String) (body : List Stmt) (close : String := "}") : Stmt := .blk [(head, body)] close

/-- `if (c) {` … `} else if (c') {` … `} else {` … `}` from the conditions and bodies, in order; a last
pair with the condition `""` is the `else`. -/
def ifChain (indent : String := "") (arms : List (String × List Stmt)) : Stmt :=
  let heads := arms.zipIdx.map fun ((c, body), i) =>
    let h := if c.isEmpty then "} else {" else if i == 0 then s!"{indent}if ({c}) \{" else s!"} else if ({c}) \{"
    (h, body)
  .blk heads

/-- A whole file: a comment header, then the statements. -/
def file (header : List String) (body : List Stmt) : String :=
  "\n".intercalate (header.map ("// " ++ ·) ++ body.flatMap (·.lines 0)) ++ "\n"

/-- An Objective-C string literal. -/
def lit (s : String) : String :=
  "@\"" ++ s.foldl (fun acc c => match c with
    | '"' => acc ++ "\\\""
    | '\\' => acc ++ "\\\\"
    | '\n' => acc ++ "\\n"
    | c => acc.push c) "" ++ "\""

/-! ## Boxed comparisons

A comparison is an `int` in C, so `@(a != b)` is a number and JSON prints it `0` or `1`; a `BOOL`, boxed,
prints `true` or `false`, and that is all a typed client takes for a boolean. The shell casts each one,
`@((BOOL)(a != b))`; `leannative-shell` finds the ones that are not (`boxedProblems`, in `Main`). -/

/-- The text up to the parenthesis that closes a `(` already read (to the line's end without one). -/
def closing : Nat → List Char → List Char → List Char
  | _, acc, [] => acc.reverse
  | 0, acc, ')' :: _ => acc.reverse
  | d + 1, acc, ')' :: cs => closing d (')' :: acc) cs
  | d, acc, '(' :: cs => closing (d + 1) ('(' :: acc) cs
  | d, acc, c :: cs => closing d (c :: acc) cs

/-- What is inside each boxed expression `@(…)` of a line, a box inside a box too. -/
def boxed : List Char → List (List Char)
  | [] => []
  | '@' :: cs => match cs with
    | '(' :: inner => closing 0 [] inner :: boxed cs
    | _ => boxed cs
  | _ :: cs => boxed cs

/-- An expression with everything inside its parentheses and brackets left out. -/
def topLevel : Nat → List Char → List Char
  | _, [] => []
  | d, c :: cs =>
    if c == '(' || c == '[' then topLevel (d + 1) cs
    else if c == ')' || c == ']' then topLevel (d - 1) cs
    else if d == 0 then c :: topLevel d cs else topLevel d cs

def hasSub (pat : List Char) : List Char → Bool
  | [] => pat.isEmpty
  | c :: cs => pat.isPrefixOf (c :: cs) || hasSub pat cs

/-- The boxed expressions of a line whose value is a comparison's or a logical operator's: an `int`, where a
`BOOL` was meant. One a `?:` chooses from is not one, nor is one under a cast (inside its parentheses). -/
def boxedInts (line : String) : List String :=
  (boxed line.toList).filterMap fun e =>
    let top := (topLevel 0 e).dropWhile (· == ' ')
    let compares := ["==", "!=", "&&", "||", "<=", ">=", " < ", " > "].any (hasSub ·.toList top)
    let negates := top.head? == some '!' && (top.drop 1).head? != some '='
    if (compares || negates) && !top.contains '?' then some (String.ofList e) else none

#guard boxedInts "answer(@{@\"records\": records, @\"more\": @(cursor != nil)});" == ["cursor != nil"]
#guard boxedInts "answer(@{@\"records\": records, @\"more\": @((BOOL)(cursor != nil))});" == []
#guard boxedInts "return @{@\"ok\": @(!error), @\"both\": @(a && [b isEqual:c])};" == ["!error", "a && [b isEqual:c]"]
#guard boxedInts "x[@(a.b)] = @[@(i), @(-1), @(++n), @([o[k] boolValue]), @((BOOL)(s == t || s == u))];" == []
#guard boxedInts "return @(n == 0 ? 1 : n), @([self has:(a == b)]), @(fetch->count);" == []

end LeanNativeShell
