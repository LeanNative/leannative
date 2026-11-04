import LeanNative.Journey
import LeanNative.Journey.Regex

/-! # The headless driver's text patterns (`Journey.Regex`) and `Journey.escapeRegex`

What a journey's `Find.text` means without a simulator: escapes, classes, counts, anchors and groups, each
matched and not matched as NSRegularExpression would, the patterns it refuses, and `escapeRegex` (behind
`Find.beginning`) round trips. -/

open LeanNative.Journey

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}" else IO.println s!"FAIL {name}"; failures.modify (· + 1)

/-- Whether `pattern` parses and its answer on `text` is `answer`. -/
def answers (pattern text : String) (answer : Bool) : Bool :=
  match Regex.matches? pattern text with
  | .ok r => r == answer
  | .error _ => false

/-- `pattern` matches each of `yes` and none of `no`. -/
def matching (pattern : String) (yes no : List String) : IO Unit := do
  for t in yes do check s!"{pattern} matches {repr t}" (answers pattern t true)
  for t in no do check s!"{pattern} does not match {repr t}" (answers pattern t false)

def refused (pattern : String) : IO Unit :=
  check s!"{pattern} is a parse error" (match Regex.parse pattern with | .error _ => true | .ok _ => false)

def escapes : IO Unit := do
  matching "a\\.b" ["a.b", "xa.by"] ["axb", "ab"]
  matching "^1\\.5 BTC$" ["1.5 BTC"] ["105 BTC", "1.5 BTCs"]
  matching "\\(none\\)" ["Complete (none)"] ["Complete none"]
  matching "\\$\\d" ["costs $5"] ["costs 5$"]
  matching "a\\\\b" ["a\\b"] ["ab", "a\\\\b"]
  matching "\\[x\\]\\{2\\}" ["[x]{2}"] ["xx", "[x]"]
  matching "a\\*\\+\\?\\|b" ["a*+?|b"] ["a", "b"]
  matching "\\^\\$" ["^$"] [""]
  matching "a\\tb" ["a\tb"] ["a b"]
  matching "a\\-b" ["a-b"] ["ab"]
  -- an escaped letter or digit this matcher does not do is refused, never read as the letter
  for p in ["\\b", "a\\Bc", "(a)\\1", "\\x41", "\\p{L}", "\\A", "\\z", "[\\b]"] do refused p

def classes : IO Unit := do
  matching "\\d" ["a1", "9"] ["ab", ""]
  matching "^\\D+$" ["abc", "a-b"] ["a1", ""]
  matching "^\\w+$" ["snake_case9"] ["two words", "a-b"]
  matching "^\\W$" ["-", " "] ["a", "_"]
  matching "a\\sb" ["a b", "a\nb"] ["ab", "a_b"]
  matching "^\\S+$" ["x_y"] ["x y"]
  matching "^[a-c]+$" ["abcabc"] ["abd", ""]
  matching "^[^0-9]+$" ["no digits"] ["4 digits"]
  matching "^[\\d.]+$" ["1.25"] ["1,25"]
  matching "^[-a]+$" ["a-a"] ["b"]
  matching "^[a-]+$" ["-a"] ["b"]
  matching "^.$" ["x"] ["", "xy"]
  for p in ["[ab", "[\\D]", "[a\\"] do refused p

def counts : IO Unit := do
  matching "^\\d{2}$" ["12"] ["1", "123", "ab"]
  matching "^\\d{2,3}$" ["12", "123"] ["1", "1234", ""]
  matching "^Count: \\d{2,3}$" ["Count: 12", "Count: 999"] ["Count: 0", "Count: 1000"]
  matching "^a{2,}$" ["aa", "aaaaa"] ["a", ""]
  matching "^a{0,1}b$" ["b", "ab"] ["aab"]
  matching "^x{0}y$" ["y"] ["xy"]
  matching "^(ab){2}$" ["abab"] ["ab", "ababab"]
  matching "^a{10}$" ["aaaaaaaaaa"] ["aaaaaaaaa"]
  matching "^a*$" ["", "aaa"] ["b"]
  matching "^a+b?$" ["a", "aab"] ["", "b", "abb"]
  -- greedy, backtracking: the count gives back what the rest needs
  matching "^\\d{1,3}1$" ["11", "1231"] ["1"]
  for p in ["a{", "a{,2}", "a{3,2}", "a{2", "a{x}", "*a", "a**", "+"] do refused p

def anchors : IO Unit := do
  matching "^Count" ["Count: 1"] ["The Count"]
  matching "1$" ["Count: 1"] ["1 more"]
  matching "^$" [""] [" "]
  matching "^(asking: )?HTTP bad proxy" ["HTTP bad proxy: {}", "asking: HTTP bad proxy…"] ["no HTTP bad proxy"]
  matching "^(Low|High)$" ["Low", "High"] ["Medium", "LowHigh"]
  matching "(?:a|b)c" ["xbc"] ["xc"]
  for p in ["(ab", "ab)", "(?ab)", "a\\"] do refused p

/-- `escapeRegex s` matches `s` itself, whole, and nothing that differs from it by a character. -/
def roundTrips : IO Unit := do
  let samples := ["Complete (none pending)", "1.5 BTC", "a+b*c?", "^$|\\", "[x]{2}", "(?:a)", "-", "", "plain words",
    "\\d{2,3}", "tb1q…ü"]
  for s in samples do
    let whole := "^" ++ escapeRegex s ++ "$"
    check s!"escapeRegex {repr s} matches itself" (answers whole s true)
    check s!"escapeRegex {repr s} does not match it with a character more" (answers whole (s ++ "x") false)
    if let some c := s.toList.head? then
      let changed := String.ofList ((if c == 'z' then 'y' else 'z') :: s.toList.tail)
      check s!"escapeRegex {repr s} does not match {repr changed}" (answers whole changed false)
  -- every printable ASCII character, escaped, is that character and only it
  let printable := (List.range 95).map fun i => Char.ofNat (32 + i)
  check "every printable ASCII character, escaped, matches itself and no other"
    (printable.all fun c => printable.all fun d =>
      answers ("^" ++ escapeRegex (String.singleton c) ++ "$") (String.singleton d) (c == d))
  -- Find.beginning: the text at the start of a label, metacharacters and all
  let begins := Find.beginning "Complete (none pending)"
  check "Find.beginning escapes its text" (begins == .text "^Complete \\(none pending\\)")
  match begins with
  | .text p =>
    matching p ["Complete (none pending)", "Complete (none pending) now"] [" Complete (none pending)", "Complete none pending"]
  | _ => check "Find.beginning is a text pattern" false

def main : IO UInt32 := do
  escapes
  classes
  counts
  anchors
  roundTrips
  let n ← failures.get
  IO.println (if n == 0 then "regex: all passed" else s!"regex: {n} FAILED")
  return if n == 0 then 0 else 1
