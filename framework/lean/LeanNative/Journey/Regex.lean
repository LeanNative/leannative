/-! # A small regular-expression matcher for the headless journey driver

`Find.text` carries an `NSRegularExpression` pattern (the XCTest and in-app drivers hand it to Foundation). The
headless driver (`LeanNative.Journey.Wire`) matches it here instead, with the part of the syntax journeys use:
literals, `.`, `\d \w \s` (and their negations), escaped metacharacters, `[…]` classes with ranges and `^`
negation, groups `(…)` with `|`, the quantifiers `* + ? {n} {n,} {n,m}` (greedy), and the anchors `^` and `$`.
A pattern outside that is a parse error, which the driver reports as the step's failure rather than matching
nothing. `search` is `firstMatchInString:` with an empty result or not: whether the pattern matches somewhere. -/

namespace LeanNative.Journey.Regex

inductive Re where
  | empty
  | char (c : Char)
  | any
  | set (negated : Bool) (ranges : List (Char × Char))
  | bol
  | eol
  | seq (a b : Re)
  | alt (a b : Re)
  /-- `r` repeated at least `lo` times, at most `hi` (none: unbounded). -/
  | rep (r : Re) (lo : Nat) (hi : Option Nat)
  deriving Repr, Inhabited

/-- Whether `r` matches at `i`, continuing with `k` at the position after the match (backtracking). -/
partial def matchAt (s : Array Char) : Re → Nat → (Nat → Bool) → Bool
  | .empty, i, k => k i
  | .char c, i, k => i < s.size && s[i]! == c && k (i + 1)
  | .any, i, k => i < s.size && k (i + 1)
  | .set neg rs, i, k =>
    i < s.size && (rs.any fun (a, b) => a ≤ s[i]! && s[i]! ≤ b) != neg && k (i + 1)
  | .bol, i, k => i == 0 && k i
  | .eol, i, k => i == s.size && k i
  | .seq a b, i, k => matchAt s a i fun j => matchAt s b j k
  | .alt a b, i, k => matchAt s a i k || matchAt s b i k
  | .rep r lo hi, i, k => repeatAt r lo hi i k
where
  repeatAt (r : Re) (lo : Nat) (hi : Option Nat) (i : Nat) (k : Nat → Bool) : Bool :=
    if lo > 0 then matchAt s r i fun j => repeatAt r (lo - 1) (hi.map (· - 1)) j k
    else if hi == some 0 then k i
    -- greedy: one more first (never an empty repetition, which would loop), then as many as matched so far
    else (matchAt s r i fun j => j != i && repeatAt r 0 (hi.map (· - 1)) j k) || k i

/-- Whether `r` matches somewhere in `text`. -/
def search (r : Re) (text : String) : Bool :=
  let s := text.toList.toArray
  (List.range (s.size + 1)).any fun i => matchAt s r i fun _ => true

/-! ## Parsing -/

private def digits : List (Char × Char) := [('0', '9')]
private def word : List (Char × Char) := [('a', 'z'), ('A', 'Z'), ('0', '9'), ('_', '_')]
private def space : List (Char × Char) := [(' ', ' '), ('\t', '\t'), ('\n', '\n'), ('\r', '\r'), ('\x0c', '\x0c'), ('\x0b', '\x0b')]

/-- An escape's class, or the literal character it stands for. -/
private def escape (c : Char) : Re :=
  match c with
  | 'd' => .set false digits
  | 'D' => .set true digits
  | 'w' => .set false word
  | 'W' => .set true word
  | 's' => .set false space
  | 'S' => .set true space
  | 'n' => .char '\n'
  | 't' => .char '\t'
  | other => .char other

private structure P where
  chars : Array Char
  pos : Nat := 0

private abbrev PM := StateT P (Except String)

private def peek? : PM (Option Char) := do let p ← get; return p.chars[p.pos]?
private def next? : PM (Option Char) := do
  let p ← get
  match p.chars[p.pos]? with
  | some c => set { p with pos := p.pos + 1 }; return some c
  | none => return none
private def expect (c : Char) : PM Unit := do
  match ← next? with
  | some d => if d == c then pure () else throw s!"expected '{c}', found '{d}'"
  | none => throw s!"expected '{c}' at the end"

private partial def number : PM (Option Nat) := do
  let mut n : Option Nat := none
  repeat
    match ← peek? with
    | some c =>
      if c.isDigit then
        discard next?
        n := some ((n.getD 0) * 10 + (c.toNat - '0'.toNat))
      else break
    | none => break
  return n

/-- `[…]`: ranges and single characters, `^` first negates; `\d` and friends inside add their ranges. -/
private partial def classBody : PM Re := do
  let negated ← match ← peek? with
    | some '^' => discard next?; pure true
    | _ => pure false
  let mut ranges : List (Char × Char) := []
  let mut first := true
  repeat
    match ← next? with
    | none => throw "unterminated character class"
    | some ']' => if first then ranges := ranges ++ [(']', ']')] else break
    | some '\\' =>
      match ← next? with
      | none => throw "a class ends with a backslash"
      | some e =>
        match escape e with
        | .set false rs => ranges := ranges ++ rs
        | .char c => ranges := ranges ++ [(c, c)]
        | _ => throw s!"\\{e} is not allowed inside a class"
    | some c =>
      -- a range `a-z` (a `-` first or last is literal)
      match ← peek? with
      | some '-' =>
        discard next?
        match ← peek? with
        | some ']' | none => ranges := ranges ++ [(c, c), ('-', '-')]
        | some hi => discard next?; ranges := ranges ++ [(c, hi)]
      | _ => ranges := ranges ++ [(c, c)]
    first := false
  return .set negated ranges

mutual
  private partial def alternation : PM Re := do
    let mut r ← sequence
    repeat
      match ← peek? with
      | some '|' => discard next?; r := .alt r (← sequence)
      | _ => break
    return r

  private partial def sequence : PM Re := do
    let mut r := Re.empty
    repeat
      match ← peek? with
      | none | some '|' | some ')' => break
      | some _ =>
        let a ← atom
        let q ← quantified a
        r := match r with | .empty => q | _ => .seq r q
    return r

  private partial def atom : PM Re := do
    match ← next? with
    | none => throw "unexpected end"
    | some '^' => return .bol
    | some '$' => return .eol
    | some '.' => return .any
    | some '(' =>
      -- a non-capturing marker is accepted and ignored
      if (← peek?) == some '?' then
        discard next?
        expect ':'
      let r ← alternation
      expect ')'
      return r
    | some '[' => classBody
    | some '\\' =>
      match ← next? with
      | none => throw "a pattern ends with a backslash"
      | some e => return escape e
    | some c =>
      if c == '*' || c == '+' || c == '?' then throw s!"'{c}' with nothing to repeat"
      return .char c

  private partial def quantified (a : Re) : PM Re := do
    match ← peek? with
    | some '*' => discard next?; return .rep a 0 none
    | some '+' => discard next?; return .rep a 1 none
    | some '?' => discard next?; return .rep a 0 (some 1)
    | some '{' =>
      discard next?
      let some lo ← number | throw "'{' without a count"
      let hi ← match ← next? with
        | some '}' => pure (some lo)
        | some ',' =>
          let hi ← number
          expect '}'
          pure hi
        | _ => throw "a malformed {n,m}"
      return .rep a lo hi
    | _ => return a
end

/-- The pattern parsed, or why not. -/
def parse (pattern : String) : Except String Re := do
  let (r, p) ← alternation.run { chars := pattern.toList.toArray }
  if p.pos < p.chars.size then throw s!"unexpected '{p.chars[p.pos]!}' at {p.pos}"
  return r

/-- Whether `pattern` (parsed) matches somewhere in `text`; an unparsable pattern is an error. -/
def matches? (pattern text : String) : Except String Bool := do return search (← parse pattern) text

end LeanNative.Journey.Regex
