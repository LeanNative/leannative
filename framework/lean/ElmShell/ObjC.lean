/-!
# ElmShell.ObjC

The Objective-C that `elmshell` prints, as a tree of lines: a line is source text, and a block is the
line that opens it, its body (one level deeper) and the line that closes it. An `if … else if … else`
chain, or a method whose block argument is followed by more of the call, is one block with several
heads (`} else {`, `} forControlEvents:…`), each with its own body. The printer indents by four spaces
per level and puts preprocessor lines at the margin.

The tree carries the shell's structure; the grammar-dependent parts of it (node decoding, the renderer's
dispatch, the events, the capabilities) are assembled from the tables in `ElmShell.Grammar` and
`ElmShell.Capabilities`.
-/

namespace ElmShell

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

end ElmShell
