import Lean
import ElmLean.Html
import ElmLean.Program
/-!
# ToSwiftLCNF: the cross-check translator (compiler IR → Swift)

A SECOND, INDEPENDENT translation of an ElmLean app into Swift, used only to cross-check the
product translator (which works on elaborated terms). This one reads the compiler's own IR:
for every declaration reachable from the app value it calls `Lean.Compiler.LCNF.toDecl`
(which builds LCNF from the kernel definition, lowering `match` to `cases`) followed by ONE
`simp` pass with `inlineDefs := false` (which resolves typeclass-instance projections such as
`instHAdd … # 0 ↦ Nat.add` and inlines matcher alternatives, but does not inline library
definitions, so the whitelist stays pinned to the names the source uses).

The output is A-normal form and is never read by humans: its only consumer is
`framework/scripts/gen_crosscheck.sh`, which compiles it with `framework/swift/Runtime.swift` and
the one-line `main.swift` (`runElmCli(<App>.self)`) and runs the lockstep differential test against the Lean binary and
against the product translator's CLI.

Contract: FAIL LOUD. Everything outside the whitelists below throws an error naming the
construct; the output file is written only after the whole translation succeeded. Every
semantic judgment the translation relies on (Nat → Int, exact String equality, …) is logged
once: to stderr and as a trailer comment at the end of the generated file.

Equality: `String` equality is exact (`unicodeScalars.elementsEqual`, never Swift's canonical
`==`); a `DecidableEq` instance on a user type is translated as an ordinary function (whatever
Lean's instance computes is what runs), so no Swift `Equatable` is emitted at all.

Run from inside an app's Lake package (no `lake build` of this file, no lakefile entry), e.g.
from `examples/todo`:

    lake env lean --run ../../framework/crosscheck/ToSwiftLCNF.lean \
        --app Todo.app --name TodoApp --out build/crosscheck/Generated.swift

    --app <Name>     the `App Model Msg` constant to translate (default `Todo.app`)
    --name <Ident>   the Swift name of the generated `enum … : ElmApp` (default `TodoApp`)
    --out <path>     where to write the Swift file (required)
    --module <Name>  module(s) to import for the app (repeatable; default: the app's root module)

The script elaborates against `ElmLean.Html`/`ElmLean.Program` (framework names only); the app
itself comes from the modules imported at run time, so any app in the library can be named.
-/

open Lean Compiler LCNF

namespace ToSwiftLCNF

inductive VarKind where
  | value
  /-- A symbolic typeclass instance (`DecidableEq`/`BEq` over `carrier`), never materialised in Swift.
  `impl` names the Lean instance when it is a user definition (translated as an ordinary function). -/
  | inst (cls : String) (carrier : Expr) (impl : Option Name)
  | fn (arity : Nat)       -- local `fun` / join point
  deriving Inhabited, BEq

structure VarInfo where
  swiftName : String
  kind : VarKind
  deriving Inhabited

inductive Role where
  | initial | update | view | helper
  deriving BEq, Inhabited

structure St where
  vars : Std.HashMap FVarId VarInfo := {}
  used : Std.HashSet String := {}
  userTypes : Array Name := #[]
  worklist : Array Name := #[]
  seen : Std.HashSet Name := {}
  declCache : Std.HashMap Name (Decl .pure) := {}
  funNames : Std.HashMap Name String := {}
  appNs : Name := .anonymous
  appSwiftName : String := ""
  lines : Array String := #[]
  /-- Deduplicated semantic judgments, in first-use order. -/
  judgments : Array String := #[]
  deriving Inhabited

abbrev M := StateRefT St CompilerM

def fail {α} (what : String) : M α :=
  throwError "ToSwiftLCNF: unsupported {what}"

/-- Record a semantic judgment (once). -/
def judge (s : String) : M Unit :=
  modify fun st => if st.judgments.contains s then st else { st with judgments := st.judgments.push s }

/-- A `toDecl` + one `simp { inlineDefs := false }` pass, cached. -/
def getUserDecl (n : Name) : M (Decl .pure) := do
  if let some d := (← get).declCache[n]? then return d
  let d ← toDecl n
  let d ← d.simp { inlineDefs := false }
  modify fun s => { s with declCache := s.declCache.insert n d }
  return d

-- ---------------------------------------------------------------- names

def swiftKeywords : List String :=
  ["in", "let", "var", "func", "return", "switch", "case", "default", "if", "else", "true", "false",
   "nil", "self", "Self", "Type", "init", "enum", "struct", "class", "protocol", "static", "import",
   "for", "while", "repeat", "do", "break", "continue", "where", "is", "as", "throw", "throws", "try",
   "catch", "guard", "defer", "extension", "subscript", "typealias", "associatedtype", "operator",
   "inout", "internal", "public", "private", "fileprivate", "open", "final", "super", "deinit",
   "fallthrough", "rethrows", "Any", "some", "any", "Int", "String", "Bool", "Optional", "Array"]

/-- Top-level names of `framework/swift/Runtime.swift` and of the Swift standard library that it uses:
nothing the translator emits may shadow them. -/
def runtimeNames : List String :=
  ["Html", "TextStyle", "ButtonRole", "Event", "ElmApp", "JNum", "JSON", "JSONReader", "Request", "Parsed",
   "Session", "q", "emit", "parseLine", "runElmCli", "Foundation", "Swift", "Int", "String", "Bool",
   "Optional", "Array", "Set", "Character", "Substring", "Unicode", "UInt8", "UInt32", "FileHandle",
   "Never", "Error", "Void", "Any", "Self", "max", "min", "zip", "fatalError", "exit", "readLine"]

/-- Hand-written Swift shims emitted verbatim at the top of the file (the only runtime code the
translator carries), with their names. -/
def preludeFuns : List (String × List String) :=
  [ ("leanTrimAscii",
     [ "/// Lean `String.trimAscii`: strips `Char.isWhitespace` (space, tab, CR, LF) from both ends.",
       "func leanTrimAscii(_ s: String) -> String {",
       "    let ws: Set<Unicode.Scalar> = [\" \", \"\\t\", \"\\r\", \"\\n\"]",
       "    var scalars = Substring(s).unicodeScalars",
       "    while let f = scalars.first, ws.contains(f) { scalars.removeFirst() }",
       "    while let l = scalars.last, ws.contains(l) { scalars.removeLast() }",
       "    return String(scalars)",
       "}" ]),
    ("leanStrEq",
     [ "/// Lean `=` on `String` is exact (Unicode scalar by scalar); Swift's `==` uses canonical equivalence.",
       "func leanStrEq(_ a: String, _ b: String) -> Bool {",
       "    return a.unicodeScalars.elementsEqual(b.unicodeScalars)",
       "}" ]) ]

def reservedNames : List String := runtimeNames ++ preludeFuns.map (·.1)

def mangleStr (str : String) : String :=
  let raw := str.map fun c => if c.isAlphanum || c == '_' then c else '_'
  let raw := if raw.isEmpty || raw.all (· == '_') then "u" else raw
  let raw := if raw.front.isDigit then "v" ++ raw else raw
  if swiftKeywords.contains raw then raw ++ "_" else raw

def mangle (n : Name) : String := mangleStr n.toString

def shortName (n : Name) : String :=
  match n with
  | .str _ s => s
  | _ => n.toString

/-- The Swift name of a user type / constructor / field: its last component, mangled. -/
def swiftIdent (n : Name) : String := mangleStr (shortName n)

def freshName (base : Name) : M String := do
  let b := mangle base
  let used := (← get).used
  let name := if used.contains b then
      (List.range 1000).findSome? (fun i => let c := s!"{b}_{i+2}"; if used.contains c then none else some c) |>.getD (b ++ "_x")
    else b
  modify fun s => { s with used := s.used.insert name }
  return name

def bindVar (fv : FVarId) (binder : Name) (kind : VarKind) : M String := do
  let name ← freshName binder
  modify fun s => { s with vars := s.vars.insert fv { swiftName := name, kind } }
  return name

def lookup (fv : FVarId) : M VarInfo := do
  match (← get).vars[fv]? with
  | some i => return i
  | none => fail s!"reference to unbound free variable {fv.name}"

def valueName (fv : FVarId) : M String := do
  let i ← lookup fv
  match i.kind with
  | .inst cls .. => fail s!"typeclass instance value ({cls}) used as a first-class value"
  | _ => return i.swiftName

def emit (ind : Nat) (line : String) : M Unit :=
  modify fun s => { s with lines := s.lines.push (String.ofList (List.replicate (4 * ind) ' ') ++ line) }

/-- Carry a Lean doc comment over as a Swift `///` doc comment. -/
def emitDoc (ind : Nat) (n : Name) : M Unit := do
  if let some doc ← findDocString? (← getEnv) n then
    for line in (doc.trimAscii.copy).splitOn "\n" do
      emit ind s!"/// {line.trimAscii.copy}"

-- ---------------------------------------------------------------- types

/-- Runtime-provided (Runtime.swift) types of the ElmLean framework. -/
def runtimeType? (n : Name) : Option String :=
  if n == ``ElmLean.TextStyle then some "TextStyle"
  else if n == ``ElmLean.ButtonRole then some "ButtonRole"
  else none

def isUserName (n : Name) : M Bool := do
  return (← get).appNs.isPrefixOf n

def recordUserType (n : Name) : M Unit :=
  modify fun s => if s.userTypes.contains n then s else { s with userTypes := s.userTypes.push n }

partial def swiftType (e : Expr) : M String := do
  match e with
  | .forallE .. =>
    let (doms, cod) := collect e #[]
    let ds ← doms.mapM swiftType
    return s!"({", ".intercalate ds.toList}) -> {← swiftType cod}"
  | _ =>
    let fn := e.getAppFn
    let args := e.getAppArgs
    match fn with
    | .const n _ =>
      if n == ``Nat && args.isEmpty then
        judge "Nat → Int: Lean naturals are unbounded, Swift Int is 64-bit (natural literals ≥ 2^62 are rejected; arithmetic leaving Int range traps instead of growing)"
        return "Int"
      if n == ``String && args.isEmpty then return "String"
      if n == ``String.Slice && args.isEmpty then
        judge "String.Slice → String: a slice is materialised by copying (`String.Slice.copy` is the identity)"
        return "String"
      if n == ``Bool && args.isEmpty then return "Bool"
      if (n == ``Unit || n == ``PUnit) && args.isEmpty then
        judge "Unit → Void"
        return "Void"
      if n == ``Decidable && args.size == 1 then
        judge "Decidable p → Bool: LCNF has already erased the proposition (`Decidable.decide` is the identity)"
        return "Bool"
      if n == ``List && args.size == 1 then
        judge "List α → Swift Array [α]; `x :: xs` → `[x] + xs` (an O(n) copy)"
        return s!"[{← swiftType args[0]!}]"
      if n == ``Option && args.size == 1 then
        judge "Option α → Optional<α> (nested options stay nested: Optional<Optional<α>>)"
        return s!"Optional<{← swiftType args[0]!}>"
      if n == ``ElmLean.Html && args.size == 1 then
        judge "Html msg → Runtime.swift's Html<Msg>: handlers become Swift closures"
        return s!"Html<{← swiftType args[0]!}>"
      if let some sw := runtimeType? n then
        if args.isEmpty then return sw
      if (← isUserName n) && args.isEmpty then
        match (← getEnv).find? n with
        | some (.inductInfo _) => recordUserType n; return swiftIdent n
        | _ => fail s!"type constant `{n}` (not an inductive type)"
      fail s!"type `{e}`"
    | .bvar _ => fail "dependent type (bound type variable)"
    | _ => fail s!"type `{e}`"
where
  collect : Expr → Array Expr → Array Expr × Expr
    | .forallE _ d b _, acc => collect b (acc.push d)
    | e, acc => (acc, e)

def stripForalls (e : Expr) (n : Nat) : M Expr :=
  match n, e with
  | 0, e => return e
  | k+1, .forallE _ _ b _ => stripForalls b k
  | _, e => fail s!"type `{e}` has fewer arrows than parameters"

-- ---------------------------------------------------------------- literals

def hex (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

def swiftStr (s : String) : String :=
  let body := s.foldl (init := "") fun acc c =>
    acc ++ (match c with
      | '\\' => "\\\\"
      | '"' => "\\\""
      | '\n' => "\\n"
      | '\r' => "\\r"
      | '\t' => "\\t"
      | c => if c.toNat < 0x20 || c.toNat == 0x7f then s!"\\u\{{hex c.toNat}}" else c.toString)
  "\"" ++ body ++ "\""

-- ---------------------------------------------------------------- equality

/-- The core `DecidableEq` instances we accept, with the type they decide equality on. -/
def coreDecEq : List (Name × Name) :=
  [ (``instDecidableEqNat, ``Nat), (``Nat.decEq, ``Nat),
    (``instDecidableEqString, ``String), (``String.decEq, ``String),
    (``instDecidableEqBool, ``Bool), (``Bool.decEq, ``Bool) ]

/-- If `n` is a `DecidableEq` instance we translate: the type whose equality it decides and, for a user
instance (derived or hand-written), the instance itself, which is translated as an ordinary function so
that exactly Lean's decision procedure runs. No Swift `Equatable` is ever emitted. -/
def decEqCarrier? (n : Name) : M (Option (Expr × Option Name)) := do
  if let some (_, t) := coreDecEq.find? (·.1 == n) then return some (mkConst t, none)
  if ← isUserName n then
    if let some ci := (← getEnv).find? n then
      if let .app (.const ``DecidableEq _) (.const tn []) := ci.type then
        if ← isUserName tn then
          if let some (.inductInfo _) := (← getEnv).find? tn then
            return some (mkConst tn, some n)
  return none

/-- Discover a user function: remember it for translation, fix its Swift name, return (name, arity).
A helper whose short name is taken (`update`/`view`, another helper, Runtime.swift, the prelude) gets a
numbered name; the generated file is internal, so the rename costs nothing. -/
def userFunction (n : Name) : M (String × Nat) := do
  let d ← getUserDecl n
  let st ← get
  let swiftName ← match st.funNames[n]? with
    | some s => pure s
    | none =>
      let base := swiftIdent n
      let taken (s : String) := reservedNames.contains s || st.funNames.toList.any (·.2 == s)
      let s := if taken base then
          (List.range 1000).findSome? (fun i => let c := s!"{base}_{i+2}"; if taken c then none else some c) |>.getD (base ++ "_x")
        else base
      modify fun st => { st with funNames := st.funNames.insert n s }
      pure s
  unless (← get).seen.contains n do
    modify fun st => { st with seen := st.seen.insert n, worklist := st.worklist.push n }
  return (swiftName, d.params.size)

/-- Swift code deciding Lean equality of two values of type `ty`, `impl` being the user instance if any. -/
def eqCode (ty : Expr) (impl : Option Name) (a b : String) : M String := do
  match ty.getAppFn, ty.getAppArgs with
  | .const ``String _, #[] =>
    judge "String equality (=, ==, !=) → leanStrEq: exact Unicode-scalar comparison; Swift's String == (canonical equivalence) is never used"
    return s!"leanStrEq({a}, {b})"
  | .const ``Nat _, #[] => return s!"({a} == {b})"
  | .const ``Bool _, #[] => return s!"({a} == {b})"
  | .const tn _, #[] =>
    let some inst := impl | fail s!"equality on `{tn}` (no translatable DecidableEq instance)"
    judge "`DecidableEq` on a user type → the Lean instance itself (derived or hand-written) translated as a function, so exactly Lean's decision procedure runs; no Swift Equatable is emitted"
    let (sw, arity) ← userFunction inst
    unless arity == 2 do fail s!"DecidableEq instance `{inst}` with arity {arity}"
    return s!"{sw}({a}, {b})"
  | _, _ => fail s!"equality on type `{ty}`"

-- ---------------------------------------------------------------- constants

def valueArgs (args : Array (Arg .pure)) : Array FVarId :=
  args.filterMap fun | .fvar f => some f | _ => none

def htmlCtorLabels : List (Name × List (Option String)) :=
  [ (``ElmLean.Html.text, [none, none]),
    (``ElmLean.Html.col, [none]),
    (``ElmLean.Html.row, [none]),
    (``ElmLean.Html.button, [some "label", some "role", some "onClick"]),
    (``ElmLean.Html.field, [some "placeholder", some "value", some "onInput", some "onSubmit"]),
    (``ElmLean.Html.toggle, [some "label", some "on", some "onToggle"]),
    (``ElmLean.Html.divider, []),
    (``ElmLean.Html.spacer, []) ]

/-- Library whitelist: every entry is a hand-written semantic claim about the Swift counterpart. -/
def libTemplate (n : Name) (a : Array String) : M (Option String) := do
  let k := a.size
  let a0 := a.getD 0 ""; let a1 := a.getD 1 ""
  match n with
  | ``List.nil => return if k == 0 then some "[]" else none
  | ``List.cons => return if k == 2 then some s!"[{a0}] + {a1}" else none
  | ``List.map | ``List.mapTR => return if k == 2 then some s!"{a1}.map({a0})" else none
  | ``List.filter | ``List.filterTR => return if k == 2 then some s!"{a1}.filter({a0})" else none
  | ``List.length | ``List.lengthTR => return if k == 1 then some s!"{a0}.count" else none
  | ``List.any => return if k == 2 then some s!"{a0}.contains(where: {a1})" else none
  | ``List.all => return if k == 2 then some s!"{a0}.allSatisfy({a1})" else none
  | ``List.isEmpty => return if k == 1 then some s!"{a0}.isEmpty" else none
  | ``List.append | ``List.appendTR => return if k == 2 then some s!"({a0} + {a1})" else none
  | ``List.reverse => return if k == 1 then some s!"Array({a0}.reversed())" else none
  | ``String.trimAscii => return if k == 1 then some s!"leanTrimAscii({a0})" else none
  | ``String.Slice.copy => return if k == 1 then some a0 else none
  | ``String.isEmpty => return if k == 1 then some s!"{a0}.isEmpty" else none
  | ``String.append => return if k == 2 then some s!"({a0} + {a1})" else none
  | ``String.utf8ByteSize =>
    if k == 1 then judge "String.utf8ByteSize → utf8.count"
    return if k == 1 then some s!"{a0}.utf8.count" else none
  | ``String.length =>
    if k == 1 then judge "String.length → unicodeScalars.count (a Lean Char is a Unicode scalar; Swift's String.count counts grapheme clusters and is never used)"
    return if k == 1 then some s!"{a0}.unicodeScalars.count" else none
  | ``Nat.add => return if k == 2 then some s!"({a0} + {a1})" else none
  | ``Nat.sub =>
    if k == 2 then judge "Nat.sub → max(a - b, 0): subtraction on naturals truncates at zero"
    return if k == 2 then some s!"max({a0} - {a1}, 0)" else none
  | ``Nat.mul => return if k == 2 then some s!"({a0} * {a1})" else none
  | ``Nat.succ => return if k == 1 then some s!"({a0} + 1)" else none
  | ``Nat.zero => return if k == 0 then some "0" else none
  | ``Nat.beq => return if k == 2 then some s!"({a0} == {a1})" else none
  | ``Nat.blt | ``Nat.decLt => return if k == 2 then some s!"({a0} < {a1})" else none
  | ``Nat.ble | ``Nat.decLe => return if k == 2 then some s!"({a0} <= {a1})" else none
  | ``Nat.repr | ``Nat.reprFast =>
    if k == 1 then judge "Nat.repr → String(Int): plain decimal digits"
    return if k == 1 then some s!"String({a0})" else none
  | ``Bool.true => return if k == 0 then some "true" else none
  | ``Bool.false => return if k == 0 then some "false" else none
  | ``Bool.Internal.not | ``not => return if k == 1 then some s!"!{a0}" else none
  | ``and => return if k == 2 then some s!"({a0} && {a1})" else none
  | ``or => return if k == 2 then some s!"({a0} || {a1})" else none
  | ``Decidable.decide => return if k == 1 then some a0 else none
  | ``Decidable.isTrue => return if k == 0 then some "true" else none     -- the proof is erased
  | ``Decidable.isFalse => return if k == 0 then some "false" else none
  | ``Option.some => return if k == 1 then some s!"Optional({a0})" else none
  | ``Option.none => return if k == 0 then some "nil" else none
  | ``PUnit.unit | ``Unit.unit => return if k == 0 then some "()" else none
  | _ => return none

/-- Translate a constant application. `none` means a symbolic instance was bound instead. -/
def translateConst (fv : FVarId) (binder : Name) (n : Name) (args : Array (Arg .pure)) (ty : Expr) :
    M (Option String) := do
  let fvs := valueArgs args
  let env ← getEnv
  -- symbolic typeclass instances and the operations that consume them
  if let some (carrier, impl) ← decEqCarrier? n then
    if fvs.size == 0 then
      discard <| bindVar fv binder (.inst "DecidableEq" carrier impl); return none
    if fvs.size == 2 then
      return some (← eqCode carrier impl (← valueName fvs[0]!) (← valueName fvs[1]!))
    fail s!"arity of `{n}` ({fvs.size} value args)"
  if n == ``instBEqOfDecidableEq then
    if fvs.size == 1 then
      if let .inst "DecidableEq" carrier impl := (← lookup fvs[0]!).kind then
        discard <| bindVar fv binder (.inst "BEq" carrier impl); return none
    fail s!"`instBEqOfDecidableEq` applied to something other than a DecidableEq instance"
  if n == ``bne || n == ``BEq.beq then
    if fvs.size == 3 then
      if let .inst "BEq" carrier impl := (← lookup fvs[0]!).kind then
        let e ← eqCode carrier impl (← valueName fvs[1]!) (← valueName fvs[2]!)
        return some (if n == ``bne then s!"!{e}" else e)
    fail s!"`{n}` with a BEq instance that is not `instBEqOfDecidableEq`"
  let a ← fvs.mapM valueName
  -- constructors
  if let some (.ctorInfo cv) := env.find? n then
    if let some (_, labels) := htmlCtorLabels.find? (·.1 == n) then
      unless labels.length == a.size do fail s!"arity of Html constructor `{n}`"
      let sw ← swiftType ty
      if a.isEmpty then return some s!"{sw}.{shortName n}"
      let parts := (labels.zip a.toList).map fun (l, x) => match l with | some l => s!"{l}: {x}" | none => x
      return some s!"{sw}.{shortName n}({", ".intercalate parts})"
    if let some sw := runtimeType? cv.induct then
      unless a.isEmpty do fail s!"runtime enum constructor `{n}` with fields"
      return some s!"{sw}.{shortName n}"
    if ← isUserName cv.induct then
      recordUserType cv.induct
      let short := swiftIdent cv.induct
      if isStructure env cv.induct then
        let fields := getStructureFields env cv.induct
        unless fields.size == a.size do fail s!"arity of structure constructor `{n}`"
        let parts := (fields.toList.zip a.toList).map fun (f, x) => s!"{mangle f}: {x}"
        return some s!"{short}({", ".intercalate parts})"
      else
        unless cv.numFields == a.size do fail s!"arity of constructor `{n}`"
        if a.isEmpty then return some s!"{short}.{swiftIdent n}"
        return some s!"{short}.{swiftIdent n}({", ".intercalate a.toList})"
    if let some t ← libTemplate n a then return some t
    fail s!"constructor `{n}`"
  -- user definitions
  if ← isUserName n then
    -- `T.ctorIdx` of a user inductive (derived DecidableEq on enum-like types unfolds to this)
    if shortName n == "ctorIdx" && a.size == 1 then
      if let some (.inductInfo _) := env.find? n.getPrefix then
        if ← isUserName n.getPrefix then
          recordUserType n.getPrefix
          return some s!"{a[0]!}.ctorIdx"
    let (swName, arity) ← userFunction n
    if a.size == arity then
      return some s!"Self.{swName}({", ".intercalate a.toList})"   -- `Self.`: a local binder with the helper's short name must not shadow it
    if a.size < arity then
      let extra ← (List.range (arity - a.size)).mapM fun _ => freshName `pa
      let all := a.toList ++ extra
      return some s!"\{ {", ".intercalate extra} in Self.{swName}({", ".intercalate all}) }"
    fail s!"over-application of `{n}` ({a.size} args, arity {arity})"
  if let some t ← libTemplate n a then return some t
  fail s!"constant `{n}` ({a.size} value args)"

-- ---------------------------------------------------------------- code

def translateLetValue (d : LetDecl .pure) : M (Option String) := do
  match d.value with
  | .lit (.nat n) =>
    if n ≥ 2^62 then fail s!"natural literal {n} (exceeds Int range)"
    return some s!"{n}"
  | .lit (.str s) => return some (swiftStr s)
  | .lit _ => fail "non Nat/String literal"
  | .erased => fail s!"erased let value for `{d.binderName}`"
  | .proj tn i x _ =>
    if tn == ``Decidable && i == 0 then return some (← valueName x)
    let env ← getEnv
    if (← isUserName tn) && isStructure env tn then
      recordUserType tn
      let fields := getStructureFields env tn
      if h : i < fields.size then
        return some s!"{← valueName x}.{mangle fields[i]}"
      fail s!"projection index {i} of `{tn}`"
    fail s!"projection `{tn}`.{i}"
  | .fvar f args =>
    let fi ← lookup f
    match fi.kind with
    | .inst cls .. => fail s!"application of a typeclass instance ({cls})"
    | _ =>
      let a ← (valueArgs args).mapM valueName
      if a.isEmpty then return some fi.swiftName
      return some s!"{fi.swiftName}({", ".intercalate a.toList})"
  | .const n _ args _ => translateConst d.fvarId d.binderName n args d.type
  | _ => fail "impure let value"

mutual

partial def translateFunDecl (fd : FunDecl .pure) (ind : Nat) : M Unit := do
  let name ← bindVar fd.fvarId fd.binderName (.fn fd.params.size)
  let ps ← fd.params.mapM fun p => do
    let pn ← bindVar p.fvarId p.binderName .value
    return s!"_ {pn}: {← swiftType p.type}"
  let ret ← swiftType (← stripForalls fd.type fd.params.size)
  emit ind s!"func {name}({", ".intercalate ps.toList}) -> {ret} \{"
  translateCode fd.value (ind + 1)
  emit ind "}"

/-- Two-way `cases` (Bool / List) lowered to `if`: the branch for `yes` runs when `cond` holds. -/
partial def emitIfElse (cond : String) (yes no : Code .pure) (ind : Nat) (bindYes : M Unit) : M Unit := do
  emit ind s!"if {cond} \{"
  bindYes
  translateCode yes (ind + 1)
  emit ind "} else {"
  translateCode no (ind + 1)
  emit ind "}"

partial def translateCases (cs : Cases .pure) (ind : Nat) : M Unit := do
  let d ← valueName cs.discr
  let env ← getEnv
  if cs.typeName == ``Bool then
    let mut tr : Option (Code .pure) := none
    let mut fl : Option (Code .pure) := none
    let mut df : Option (Code .pure) := none
    for alt in cs.alts do
      match alt with
      | .alt ``Bool.true _ k _ => tr := some k
      | .alt ``Bool.false _ k _ => fl := some k
      | .default k => df := some k
      | _ => fail "Bool cases alternative"
    match tr <|> df, fl <|> df with
    | some t, some f => emitIfElse d t f ind (pure ())
    | _, _ => fail "incomplete Bool cases"
    return
  if cs.typeName == ``List then
    judge "match on List → `isEmpty` / `[0]` / `Array(dropFirst())` (the tail is copied)"
    let mut nilK : Option (Code .pure) := none
    let mut consK : Option (Array (Param .pure) × Code .pure) := none
    let mut df : Option (Code .pure) := none
    for alt in cs.alts do
      match alt with
      | .alt ``List.nil _ k _ => nilK := some k
      | .alt ``List.cons ps k _ => consK := some (ps, k)
      | .default k => df := some k
      | _ => fail "List cases alternative"
    let consBranch := consK.map (·.2) <|> df
    match nilK <|> df, consBranch with
    | some nk, some ck =>
      let consParams := consK.map (·.1)
      let bindCons : M Unit := do
        if let some #[h, t] := consParams then
          let hn ← bindVar h.fvarId h.binderName .value
          emit (ind + 1) s!"let {hn}: {← swiftType h.type} = {d}[0]"
          let tn ← bindVar t.fvarId t.binderName .value
          emit (ind + 1) s!"let {tn}: {← swiftType t.type} = Array({d}.dropFirst())"
        else if consParams.isSome then fail "List.cons cases arity"
      -- `if d.isEmpty { nil } else { cons }`: arrange so the cons bindings go into the else branch
      emit ind s!"if {d}.isEmpty \{"
      translateCode nk (ind + 1)
      emit ind "} else {"
      bindCons
      translateCode ck (ind + 1)
      emit ind "}"
    | _, _ => fail "incomplete List cases"
    return
  if cs.typeName == ``Option then
    judge "match on Option → `switch` with `.none` / `.some(let x)`"
    emit ind s!"switch {d} \{"
    for alt in cs.alts do
      match alt with
      | .alt ``Option.none #[] k _ =>
        emit ind "case .none:"
        translateCode k (ind + 1)
      | .alt ``Option.some #[p] k _ =>
        let pn ← bindVar p.fvarId p.binderName .value
        emit ind s!"case .some(let {pn}):"
        translateCode k (ind + 1)
      | .default k =>
        emit ind "default:"
        translateCode k (ind + 1)
      | _ => fail "Option cases alternative"
    emit ind "}"
    return
  unless ← isUserName cs.typeName do fail s!"cases on `{cs.typeName}`"
  recordUserType cs.typeName
  if isStructure env cs.typeName then
    let fields := getStructureFields env cs.typeName
    match cs.alts with
    | #[.alt _ params k _] =>
      unless params.size == fields.size do fail "structure cases arity"
      for p in params, f in fields do
        let pn ← bindVar p.fvarId p.binderName .value
        emit ind s!"let {pn}: {← swiftType p.type} = {d}.{mangle f}"
      translateCode k ind
    | _ => fail "structure cases shape"
    return
  emit ind s!"switch {d} \{"
  for alt in cs.alts do
    match alt with
    | .alt ctor params k _ =>
      if params.isEmpty then
        emit ind s!"case .{swiftIdent ctor}:"
      else
        let ps ← params.mapM fun p => do return s!"let {← bindVar p.fvarId p.binderName .value}"
        emit ind s!"case .{swiftIdent ctor}({", ".intercalate ps.toList}):"
      translateCode k (ind + 1)
    | .default k =>
      emit ind "default:"
      translateCode k (ind + 1)
    | _ => fail "cases alternative kind"
  emit ind "}"

partial def translateCode (c : Code .pure) (ind : Nat) : M Unit := do
  match c with
  | .let d k =>
    match ← translateLetValue d with
    | some e =>
      let ty ← swiftType d.type
      let n ← bindVar d.fvarId d.binderName .value
      emit ind s!"let {n}: {ty} = {e}"
    | none => pure ()
    translateCode k ind
  | .fun fd k _ => translateFunDecl fd ind; translateCode k ind
  | .jp fd k => translateFunDecl fd ind; translateCode k ind
  | .jmp j args =>
    let fi ← lookup j
    let a ← (valueArgs args).mapM valueName
    emit ind s!"return {fi.swiftName}({", ".intercalate a.toList})"
  | .cases cs => translateCases cs ind
  | .return x => emit ind s!"return {← valueName x}"
  | .unreach _ =>
    judge "unreachable LCNF code → fatalError(\"unreachable\")"
    emit ind "fatalError(\"unreachable\")"
  | _ => fail "impure code construct"

end

-- ---------------------------------------------------------------- declarations

def translateDecl (n : Name) (role : Role) : M Unit := do
  let d ← getUserDecl n
  -- locals must not shadow translated functions, the prelude or Runtime.swift names
  modify fun s => { s with
    used := s.funNames.fold (fun acc _ v => acc.insert v) (Std.HashSet.ofList reservedNames) }
  let .code body := d.value | fail s!"extern declaration `{n}`"
  let st ← get
  let swName := match role with
    | .initial => "initial"
    | .update => "update"
    | .view => "view"
    | .helper => st.funNames[n]?.getD (swiftIdent n)
  let ret ← swiftType (← stripForalls d.type d.params.size)
  emitDoc 1 n
  emit 1 s!"// from `{n}`"
  match role with
  | .initial =>
    unless d.params.isEmpty do fail "an `init` with parameters"
    emit 1 s!"static var {swName}: {ret} \{"
  | _ =>
    let ps ← d.params.mapM fun p => do
      let pn ← bindVar p.fvarId p.binderName .value
      return s!"_ {pn}: {← swiftType p.type}"
    emit 1 s!"static func {swName}({", ".intercalate ps.toList}) -> {ret} \{"
  translateCode body 2
  emit 1 "}"
  emit 1 ""

/-- Find `App.mk init update view` in the app value and return the three constant names. -/
def findAppFields (appDecl : Name) : M (Name × Name × Name) := do
  unless (← getEnv).contains appDecl do fail s!"app constant `{appDecl}` (not found in the imported modules)"
  let d ← getUserDecl appDecl
  let .code body := d.value | fail "extern app value"
  let mut lets : Std.HashMap FVarId (LetValue .pure) := {}
  let mut cur := body
  repeat
    match cur with
    | .let ld k => lets := lets.insert ld.fvarId ld.value; cur := k
    | _ => break
  let some (_, .const ``ElmLean.App.mk _ args _) := lets.toList.find? (fun (_, v) => match v with | .const ``ElmLean.App.mk .. => true | _ => false)
    | fail s!"app value `{appDecl}` is not a plain `App.mk` record"
  let fvs := valueArgs args
  unless fvs.size == 3 do fail "App.mk arity"
  let resolve (f : FVarId) : M Name := do
    match lets[f]? with
    | some (.const c _ #[] _) => return c
    | _ => fail "App.mk field that is not a named constant"
  return (← resolve fvs[0]!, ← resolve fvs[1]!, ← resolve fvs[2]!)

/-- Field (name, type) pairs of a constructor, from its type telescope. -/
def ctorFields (cv : ConstructorVal) : M (List (Name × Expr)) := do
  let rec go (e : Expr) (skip : Nat) (acc : List (Name × Expr)) : M (List (Name × Expr)) :=
    match e with
    | .forallE bn d b _ =>
      if skip > 0 then go b (skip - 1) acc
      else
        if b.hasLooseBVars then fail s!"dependent field `{bn}` of `{cv.name}`" else go b 0 (acc ++ [(bn, d)])
    | _ => return acc
  go cv.type cv.numParams []

/-- A user type as a plain Swift value type. No `Equatable`: Lean's `DecidableEq` instances are translated
as functions (see `eqCode`), so Swift's synthesized `==` (canonical String equivalence) never runs. -/
def emitType (n : Name) : M Unit := do
  let env ← getEnv
  let some (.inductInfo iv) := env.find? n | fail s!"type `{n}` is not an inductive type"
  unless iv.numIndices == 0 do fail s!"indexed family `{n}`"
  unless iv.numParams == 0 do fail s!"parametric user type `{n}`"
  let short := swiftIdent n
  if reservedNames.contains short then fail s!"type name `{short}` (from `{n}`): it collides with a Runtime.swift / prelude name"
  emitDoc 0 n
  if isStructure env n then
    if iv.isRec then fail s!"recursive structure `{n}` (a Swift value type cannot contain itself)"
    let [ctor] := iv.ctors | fail "structure with several constructors"
    let some (.ctorInfo cv) := env.find? ctor | fail "ctor info"
    let fields ← ctorFields cv
    emit 0 s!"struct {short} \{"
    for (f, t) in fields do
      emitDoc 1 (n ++ f)
      emit 1 s!"var {mangle f}: {← swiftType t}"
    emit 0 "}"
  else
    let indirect := if iv.isRec then "indirect " else ""
    if iv.isRec then judge "recursive inductive type → `indirect enum` (boxed payloads)"
    emit 0 s!"{indirect}enum {short} \{"
    let mut idxCases : Array String := #[]
    for ctor in iv.ctors, i in List.range iv.ctors.length do
      let some (.ctorInfo cv) := env.find? ctor | fail "ctor info"
      let fields ← ctorFields cv
      let tys ← fields.mapM fun (_, t) => swiftType t
      emitDoc 1 ctor
      emit 1 (if tys.isEmpty then s!"case {swiftIdent ctor}" else s!"case {swiftIdent ctor}({", ".intercalate tys})")
      idxCases := idxCases.push s!"case .{swiftIdent ctor}: return {i}"
    emit 1 "/// Lean `T.ctorIdx` (derived DecidableEq on enum-like types compares these)."
    emit 1 "var ctorIdx: Int { switch self {"
    for c in idxCases do emit 2 c
    emit 1 "} }"
    emit 0 "}"

/-- Translation-time check that no two emitted Swift names collide (types, the app enum, the prelude,
Runtime.swift, and the app's static members). -/
def checkCollisions : M Unit := do
  let st ← get
  let typeNames := st.userTypes.map swiftIdent
  let mut seen : Std.HashSet String := Std.HashSet.ofList reservedNames
  for (n, t) in st.userTypes.zip typeNames do
    if seen.contains t then fail s!"Swift name `{t}` (from type `{n}`): it collides with another emitted or reserved name"
    seen := seen.insert t
  if seen.contains st.appSwiftName then fail s!"app name `{st.appSwiftName}`: it collides with an emitted or reserved name"
  let members := st.funNames.toList.map (·.2)
  for m in members do
    if typeNames.contains m then fail s!"member name `{m}`: it collides with a type name"
    if reservedNames.contains m then fail s!"member name `{m}`: it collides with a Runtime.swift / prelude name"
  for (n, s) in st.funNames.toList do
    if (members.filter (· == s)).length > 1 then fail s!"member name `{s}` (from `{n}`) is emitted twice"

/-- Translate every discovered helper (the worklist grows while translating). -/
partial def drainWorklist : M Unit := do
  let st ← get
  if h : 0 < st.worklist.size then
    let n := st.worklist[0]
    set { st with worklist := st.worklist.eraseIdx 0 }
    translateDecl n .helper
    drainWorklist

/-- Close the user types under constructor field types and print them (into `lines`). -/
partial def emitTypes (i : Nat := 0) : M Unit := do
  let tys := (← get).userTypes
  if h : i < tys.size then
    emitType tys[i]
    emitTypes (i + 1)

def generate (appDecl : Name) (appSwiftName : String) : M String := do
  modify fun s => { s with appNs := appDecl.getPrefix, appSwiftName }
  let (initN, updN, viewN) ← findAppFields appDecl
  for (n, sw) in [(initN, "initial"), (updN, "update"), (viewN, "view")] do
    modify fun s => { s with funNames := s.funNames.insert n sw, seen := s.seen.insert n }
  translateDecl initN .initial
  translateDecl updN .update
  translateDecl viewN .view
  drainWorklist
  let funcs := (← get).lines
  modify fun s => { s with lines := #[] }
  emitTypes
  let types := (← get).lines
  checkCollisions
  let judgments := (← get).judgments
  let header :=
    [ s!"// GENERATED by framework/crosscheck/ToSwiftLCNF.lean from the LCNF of `{appDecl}` (Lean {Lean.versionString}); do not edit.",
      "// Pipeline: Lean.Compiler.LCNF.toDecl → Decl.simp { inlineDefs := false } → Swift (A-normal form).",
      "// This is the CROSS-CHECK translation; it is compiled only by framework/scripts/gen_crosscheck.sh.",
      "" ]
  let prelude := preludeFuns.foldl (fun acc (_, ls) => acc ++ ls ++ [""]) []
  let trailer :=
    [ "", "// ---- translator judgments (deduplicated; each is a semantic decision the translation relies on) ----" ]
    ++ judgments.toList.map (s!"// * {·}")
  let body := header ++ prelude ++ types.toList ++ ["", s!"enum {appSwiftName}: ElmApp \{"] ++ funcs.toList ++ ["}"] ++ trailer
  return "\n".intercalate body ++ "\n"

/-- Translate the app named `appDecl`; returns the Swift text and the judgment log. -/
def run (appDecl : Name) (appSwiftName : String) : CoreM (String × Array String) :=
  CompilerM.run (phase := .base) <| (do
    let text ← generate appDecl appSwiftName
    return (text, (← get).judgments) : M _).run' {}

/-- Test hook: translate one declaration as a helper (with everything it reaches, types included), in a
scratch app namespace. -/
def translateOne (n : Name) : CoreM String :=
  CompilerM.run (phase := .base) <| (do
    modify fun s => { s with appNs := n.getPrefix, appSwiftName := "TodoApp" }
    discard <| userFunction n
    drainWorklist
    emitTypes
    checkCollisions
    return "\n".intercalate (← get).lines.toList : M String).run' {}

-- ---------------------------------------------------------------- command line

structure Args where
  app : Name := `Todo.app
  name : String := "TodoApp"
  out : Option String := none
  modules : Array Name := #[]

def usage : String :=
  "usage: lake env lean --run framework/crosscheck/ToSwiftLCNF.lean --out <file.swift> [--app <Name>] [--name <SwiftName>] [--module <Name>]..."

def parseArgs : List String → Args → Except String Args
  | [], a => .ok a
  | "--app" :: v :: rest, a => parseArgs rest { a with app := v.toName }
  | "--name" :: v :: rest, a => parseArgs rest { a with name := v }
  | "--out" :: v :: rest, a => parseArgs rest { a with out := some v }
  | "--module" :: v :: rest, a => parseArgs rest { a with modules := a.modules.push v.toName }
  | x :: _, _ => .error s!"unexpected argument `{x}`"

end ToSwiftLCNF

open ToSwiftLCNF in
unsafe def main (args : List String) : IO UInt32 := do
  let a ← match parseArgs args {} with
    | .error e => IO.eprintln s!"ToSwiftLCNF: {e}\n{usage}"; return 2
    | .ok a => pure a
  let some out := a.out | IO.eprintln s!"ToSwiftLCNF: --out is required\n{usage}"; return 2
  try
    enableInitializersExecution
    initSearchPath (← findSysroot)
    let mods := if a.modules.isEmpty then #[a.app.getRoot] else a.modules
    let env ← importModules (mods.map fun m => { module := m }) {} (trustLevel := 0) (loadExts := true)
    let ((text, judgments), _) ← (run a.app a.name).toIO { fileName := "<ToSwiftLCNF>", fileMap := default } { env }
    for j in judgments do IO.eprintln s!"ToSwiftLCNF: judgment: {j}"
    if let some dir := (System.FilePath.mk out).parent then IO.FS.createDirAll dir
    IO.FS.writeFile out text
    IO.println s!"ToSwiftLCNF: wrote {out} ({text.length} chars, {judgments.size} judgments)"
    return 0
  catch e =>
    IO.eprintln s!"ToSwiftLCNF: FAILED: {e}"
    return 1
