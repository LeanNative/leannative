import Lean
import ElmGen.SwiftAST
import ElmGen.Tables
/-!
# ElmGen.Translate

Lean → Swift translation of ELABORATED definitions (`ConstantInfo.value`), i.e. exactly the
constants the theorems are about, decomposed with the public `Lean.Meta` API (`lambdaTelescope`,
`matchMatcherApp?`, `getStructureFields`, …).

Whitelist philosophy: every construct outside the tables below makes the translator THROW, naming
the construct; it never guesses.  Nothing app-specific is hard-coded: the entry point is an
`App Model Msg` constant and every definition / inductive reachable from its three fields inside
the app namespace is translated.  The result is an intermediate tree (`DefIR` / `TypeIR` over
`SExpr` / `SStmt`) consumed by two printers: `ElmGen.Emit` (the `ElmApp` enum) and
`ElmGen.Screen` (the SwiftUI screen).

Every semantic decision (Nat → Int, Slice → String, …) is recorded once in the judgment log.
-/

namespace ElmGen
open Lean Meta

/-! ## IR records kept for the printers -/

structure DefIR where
  leanName : Name
  swiftName : String
  doc : Option String := none
  params : List (String × String)   -- (Swift name, Swift type)
  ret : String
  retHtml : Bool
  body : List SStmt

inductive TypeBody where
  /-- fields: (name, type, doc) -/
  | struct (fields : List (String × String × Option String))
  /-- cases: (name, payload types, doc) -/
  | enum (indirect : Bool) (cases : List (String × List String × Option String))

structure TypeIR where
  leanName : Name
  swiftName : String
  doc : Option String
  equatable : Bool
  body : TypeBody

/-- How one value crosses the JSON boundary between the app and its host (commands out, host answers
in), in the format of Lean's derived `ToJson` / `FromJson`. -/
inductive Codec where
  | nat
  | str
  | bool
  | list (c : Codec)
  | opt (c : Codec)
  /-- an app type with its own codec (its Swift name) -/
  | named (swift : String)
  deriving Inhabited

inductive CodecBody where
  /-- fields: (JSON key, Swift field name, codec) -/
  | struct (fields : List (String × String × Codec))
  /-- cases: (JSON tag, Swift case name, [(JSON key, codec)] for the payload, in order) -/
  | enum (cases : List (String × String × List (String × Codec)))

structure CodecIR where
  swiftName : String
  body : CodecBody

/-- The extra members and codecs of an app with commands (`CmdApp`). -/
structure CmdGen where
  cmdType : String
  hostType : String
  codecs : Array CodecIR

structure GenResult where
  appConst : Name
  appName : String
  screenName : String
  types : Array TypeIR
  /-- app definitions in worklist order (the ones the `App` fields are, or reach) -/
  defs : Array DefIR
  /-- `ElmApp` members that wrap a field expression which is not itself a same-named definition -/
  members : Array DefIR
  shims : Array String
  judgments : Array String
  /-- present for an app with commands -/
  cmd : Option CmdGen := none

/-! ## Translation monad -/

structure Ctx where
  appNs : Name
  appName : String
  screenName : String
  names : Std.HashMap FVarId String := {}
  /-- Swift local names in scope (seeded with the reserved local names and every app constant's short name). -/
  used : List String := []

structure St where
  pendingDefs : Array Name := #[]
  doneDefs : NameSet := {}
  defs : Array DefIR := #[]
  pendingTypes : Array Name := #[]
  doneTypes : NameSet := {}
  types : Array TypeIR := #[]
  shims : Array String := #[]
  /-- deduplicated, in order of first occurrence -/
  judgments : Array String := #[]
  /-- Swift identifier → (owner, description of the owner) for the collision check -/
  swiftNames : Std.HashMap String (Name × String) := {}

abbrev TransM := ReaderT Ctx (StateRefT St MetaM)

/-- Pretty-print eagerly (inside `MetaM`): a lazily formatted `Expr` in a message that is rendered
after the translation monad has finished crashes the compiled `elmgen` binary. -/
def showExpr (e : Expr) : MetaM String := do
  try pure ((← ppExpr e).pretty 100000) catch _ => pure (toString e)

def unsupported (what : String) (e : Expr) : TransM α := do
  throwError "elmgen: unsupported {what}: {← showExpr e}"

def fail (msg : String) : TransM α :=
  throwError "elmgen: {msg}"

/-- Record a semantic judgment (once). -/
def judge (s : String) : TransM Unit :=
  modify fun st => if st.judgments.contains s then st else { st with judgments := st.judgments.push s }

/-- Give Swift names to local fvars (created by `forallTelescope`/`withLocalDecl`) for the scope `k`. -/
def withNames (fvars : Array Expr) (k : TransM α) : TransM α := do
  let mut names := (← read).names
  let mut used := (← read).used
  for x in fvars do
    let decl ← x.fvarId!.getDecl
    let n := freshName (sanitize decl.userName) used
    names := names.insert x.fvarId! n
    used := n :: used
  withReader (fun c => { c with names := names, used := used }) k

def nameOf (x : Expr) : TransM String := do
  match (← read).names[x.fvarId!]? with
  | some n => pure n
  | none => unsupported "free variable (not bound by a translated binder)" x

def inAppNs (n : Name) : TransM Bool := do pure ((← read).appNs.isPrefixOf n)

/-- The Swift name of an app-namespace constant: `Todo.Model.init` → `Model_init`. -/
def shortName (n : Name) : TransM String := do
  let ns := (← read).appNs
  if !ns.isPrefixOf n then unsupported "constant outside the app namespace" (mkConst n)
  pure (sanitize (n.replacePrefix ns .anonymous))

/-- Translation-time name-collision check: every Swift identifier the generated files introduce
(types, app members, shims, `ElmApp` members) is claimed here; a second owner or a reserved name throws. -/
def claimName (swift : String) (owner : Name) (desc : String) : TransM Unit := do
  let c ← read
  -- the app shell of the template and the examples is `<Name>GenApp` for the Swift app `<Name>App`
  let shell := if c.appName.endsWith "App" then String.ofList (c.appName.toList.take (c.appName.length - 3)) ++ "GenApp" else c.appName ++ "GenApp"
  if reservedSwiftNames.contains swift || swift == c.appName || swift == c.screenName || swift == shell then
    fail s!"Swift name `{swift}` (from {desc}) collides with a name the Swift runtime, SwiftUI or the generated app already uses; rename the Lean declaration"
  match (← get).swiftNames[swift]? with
  | some (o, odesc) =>
    if o != owner then
      fail s!"Swift name `{swift}` is produced by both {odesc} and {desc}; rename one of them"
  | none => modify fun st => { st with swiftNames := st.swiftNames.insert swift (owner, desc) }

def requestType (n : Name) : TransM Unit := do
  let st ← get
  if st.doneTypes.contains n || st.pendingTypes.contains n then return
  claimName (← shortName n) n s!"the inductive type `{n}`"
  modify fun s => { s with pendingTypes := s.pendingTypes.push n }

def requestDef (n : Name) : TransM Unit := do
  let st ← get
  if st.doneDefs.contains n || st.pendingDefs.contains n then return
  claimName (← shortName n) n s!"the definition `{n}`"
  modify fun s => { s with pendingDefs := s.pendingDefs.push n }

def requestShim (s : String) : TransM Unit := do
  if (← get).shims.contains s then return
  claimName (shimSwiftName s) (`elmgen.shim ++ Name.mkSimple s) s!"the `{shimSwiftName s}` shim"
  modify fun st => { st with shims := st.shims.push s }

/-! ## Judgment texts -/

def jNat := "Nat → Int: Lean's Nat is unbounded, Swift's Int is 64-bit and traps on overflow (+ and * are mapped; literals are range-checked)"
def jNatSub := "Nat subtraction → max(a - b, 0): Lean's `-` on Nat truncates at zero"
def jSlice := "String.Slice → String: a slice is represented by its copy"
def jList := "List → Array (value semantics; map / filter / count keep the order)"
def jOption := "Option → Optional"
def jStrEq := "= / == / != on String → unicodeScalars.elementsEqual (exact code points; Swift's String == uses canonical equivalence)"
def jIte := "if-then-else on a decidable Prop → Swift Bool condition (the Decidable instance is erased)"
def jMatch := "match → switch with the alternatives in source order (Lean's exhaustiveness guarantees Swift's); unused pattern variables print as _"
def jNested := "nested constructor / Bool / Option patterns → nested Swift patterns"
def jListPat := "List pattern ([] / h :: t) → if xs.isEmpty { … } else { let h = xs[0]; let t = Array(xs.dropFirst()); … }"
def jLet := "let in tail position → Swift let; let / match in expression position → immediately applied closure"
def jLambda := "fun → Swift closure with explicit parameter and return types; an under-applied function is eta-expanded"
def jStruct := "structure → struct with the same fields; { m with f := v } → a fresh struct value"
def jEnum := "inductive → enum with positional payloads"
def jIndirect := "recursive inductive → indirect enum"
def jDoc := "Lean doc comments → Swift /// comments"
def jSome := "some x / none → Optional<T>.some(x) / Optional<T>.none (explicit T so nested options stay distinct)"
def jCons := "a :: b :: [] → array literal; a :: tail → [a] + tail"
def jAppend := "++ on String / List → +"
def jAny := "List.any p → contains(where: p)"
def jAll := "List.all p → allSatisfy(p)"
def jLength := "List.length → count"
def jStrLength := "String.length → unicodeScalars.count (code points, as in Lean)"
def jToStringNat := "toString (n : Nat) → String(n)"
def jToStringBool := "toString (b : Bool) → \"true\" / \"false\""
def jSucc := "Nat.succ n → n + 1"
def jReverse := "List.reverse → Array(xs.reversed())"
def jTrim := "(String.trimAscii s).copy → leanTrimAscii(s) shim (strips ' ', \\t, \\r, \\n at both ends, by code point)"
def jIsEmpty := "String.isEmpty / List.isEmpty → isEmpty"
def jBoolOps := "Bool not / and / or → ! && || (both operands are already evaluated values; && and || short-circuit, which is unobservable for pure code)"
def jNatCmp := "< ≤ > ≥ on Nat → the Swift comparison on Int"
def jHtml := "Html constructors → Html<Msg>.ctor(…) of Runtime.swift (labels for button / field / toggle are the Lean binder names)"
def jRole := "ButtonRole / TextStyle → the Runtime.swift enums of the same name"
def jCmdApp := "CmdApp → CmdElmApp: `cmds` and `host` become static members; the runtime computes `cmds(msg, model)` from the pre-state, before `update`, exactly as `Session.step` does"
def jCodec := "Cmd / Host types (and every type they contain) → LeanCodable: the JSON of Lean's derived ToJson / FromJson (structure → object of all fields, Option none → null and a missing Option key → none, constructor with fields → {\"tag\":{fields}}, nullary constructor → \"tag\", Nat → a number whose value is a natural with no fractional digits beyond the exponent)"

/-! ## Types -/

partial def swiftType (t : Expr) : TransM String := do
  let t := t.consumeMData
  match t with
  | .const `Nat _ => judge jNat; pure "Int"
  | .const `String _ => pure "String"
  | .const `Bool _ => pure "Bool"
  | .const `String.Slice _ => judge jSlice; pure "String"
  | .const `ElmLean.ButtonRole _ => judge jRole; pure "ButtonRole"
  | .const `ElmLean.TextStyle _ => judge jRole; pure "TextStyle"
  | .const n _ =>
    if ← inAppNs n then
      if (← getEnv).find? n matches some (.inductInfo _) then
        requestType n
        shortName n
      else unsupported "type constant" t
    else unsupported "type constant" t
  | .app (.const `List _) a => judge jList; pure s!"[{← swiftType a}]"
  | .app (.const `Option _) a => judge jOption; pure s!"{← swiftType a}?"
  | .app (.const `ElmLean.Html _) a => pure s!"Html<{← swiftType a}>"
  | .forallE _ d b _ =>
    if b.hasLooseBVars then unsupported "dependent function type" t
    pure s!"({← swiftType d}) -> {← swiftType b}"
  | _ => unsupported "type" t

/-- Does the (possibly function) type return `Html`? -/
def retHtmlOf (ty : Expr) : MetaM Bool :=
  forallTelescope ty fun _ r => pure (r.consumeMData.isAppOf `ElmLean.Html)

/-- Lean has `DecidableEq` for the type (so `=` on it is decidable in the first place). -/
def hasDecEq (ty : Expr) : TransM Bool := do
  try
    let u ← getLevel ty
    let inst ← synthInstance? (mkApp (mkConst ``DecidableEq [u]) ty)
    pure inst.isSome
  catch _ => pure false

/-- Would Swift's `==` on the translated type agree with Lean's `=`?  `none` means yes; `some reason`
names the obstacle (no `DecidableEq`, or a `String` reachable through the fields: Swift's synthesized
`==` would compare it by canonical equivalence). -/
partial def eqInexact (ty : Expr) (visiting : List Name := []) : TransM (Option String) := do
  let ty := ty.consumeMData
  match ty with
  | .const `Nat _ | .const `Bool _ | .const `ElmLean.ButtonRole _ | .const `ElmLean.TextStyle _ => pure none
  | .const `String _ => pure (some "String (Swift's String == uses canonical equivalence, Lean's = is exact)")
  | .app (.const `Option _) a => eqInexact a visiting
  | .app (.const `List _) a => eqInexact a visiting
  | .const n _ =>
    if visiting.contains n then return none
    unless ← inAppNs n do return some s!"{n} (not an app type)"
    let some (.inductInfo ind) := (← getEnv).find? n | return some s!"{n} (not an inductive type)"
    unless ← hasDecEq ty do return some s!"{n} (no DecidableEq instance in Lean)"
    for c in ind.ctors do
      let ci ← getConstInfoCtor c
      let r ← forallTelescope ci.type fun xs _ => do
        let mut r : Option String := none
        for x in xs.extract ci.numParams xs.size do
          if r.isNone then r ← eqInexact (← inferType x) (n :: visiting)
        pure r
      if let some reason := r then return some s!"{n} has a field of type {reason}"
    pure none
  | _ => pure (some s!"{ty}")

/-! ## Literals -/

def swiftStringLit (s : String) : String := Id.run do
  let mut out := "\""
  for c in s.toList do
    if c == '"' then out := out ++ "\\\""
    else if c == '\\' then out := out ++ "\\\\"
    else if c == '\n' then out := out ++ "\\n"
    else if c == '\r' then out := out ++ "\\r"
    else if c == '\t' then out := out ++ "\\t"
    else if c.toNat < 0x20 || c.toNat == 0x7f then out := out ++ s!"\\u\{{String.ofList (Nat.toDigits 16 c.toNat)}}"
    else out := out.push c
  return out ++ "\""

def natLit (n : Nat) (e : Expr) : TransM SExpr := do
  judge jNat
  if n ≥ 2 ^ 63 then unsupported "numeric literal (does not fit a 64-bit Int)" e
  pure (.raw (toString n))

/-! ## Helpers over constructors and definitions -/

def ctorFieldNames (c : Name) : TransM (Array String) := do
  let ci ← getConstInfoCtor c
  forallTelescope ci.type fun xs _ => do
    let mut out := #[]
    for x in (xs.extract ci.numParams xs.size) do
      out := out.push (sanitize (← x.fvarId!.getDecl).userName)
    pure out

/-- Explicit arity of a constant's type (all binders must be explicit; the Swift side has no place
for implicit or instance arguments). -/
def explicitArity (ty : Expr) : TransM Nat := do
  forallTelescope ty fun xs _ => do
    for x in xs do
      if (← x.fvarId!.getDecl).binderInfo != .default then
        unsupported "implicit/instance binder in definition type" ty
    pure xs.size

/-- A pattern recovered from a matcher alternative, per discriminant. -/
inductive Pat where
  | var                                  -- variable or wildcard (the body already refers to the discriminant)
  | swift (text : String)                -- a (possibly nested) Swift pattern
  | listNil
  | listCons (h t : Option String)       -- Swift names of the bound head / tail (none when unused)
  deriving Inhabited

def Pat.isList : Pat → Bool
  | .listNil | .listCons .. => true
  | _ => false

def Pat.text : Pat → String
  | .swift t => t
  | _ => "_"

def isListPat (p : Expr) : Bool := p.isAppOfArity `List.nil 1 || p.isAppOfArity `List.cons 3

/-! ## Expressions -/

mutual

/-- Tail-position translation: statements ending in `return`. -/
partial def stmts (e : Expr) : TransM (List SStmt) := do
  let e := e.consumeMData
  match e with
  | .letE n t v b _ =>
    judge jLet
    let v' ← expr v
    withLocalDecl n .default t fun x => withNames #[x] do
      let rest ← stmts (b.instantiate1 x)
      pure (.letS (← nameOf x) v' :: rest)
  | _ =>
    if e.isAppOfArity ``ite 5 then
      judge jIte
      let args := e.getAppArgs
      pure [.ite (← cond args[1]!) (← stmts args[3]!) (← stmts args[4]!)]
    else if let some ma ← matchMatcherApp? e then
      transMatch ma
    else
      pure [.ret (← expr e)]

/-- A `Prop` used as an `if` condition (its `Decidable` instance is erased). -/
partial def cond (p : Expr) : TransM SExpr := do
  let p := p.consumeMData
  let fn := p.getAppFn
  let args := p.getAppArgs
  match fn.constName?, args.size with
  | some ``Eq, 3 =>
    match args[0]!.consumeMData, args[2]!.consumeMData with
    | .const ``Bool _, .const ``Bool.true _ => expr args[1]!
    | .const ``Bool _, .const ``Bool.false _ => pure (.unop "!" (← expr args[1]!))
    | _, _ => eqExpr "==" args[0]! args[1]! args[2]!
  | some ``Ne, 3 => eqExpr "!=" args[0]! args[1]! args[2]!
  | some ``Not, 1 => pure (.unop "!" (← cond args[0]!))
  | some ``And, 2 => pure (.binop "&&" (← cond args[0]!) (← cond args[1]!))
  | some ``Or, 2 => pure (.binop "||" (← cond args[0]!) (← cond args[1]!))
  | some ``LT.lt, 4 => natCmp "<" args
  | some ``LE.le, 4 => natCmp "<=" args
  | some ``GT.gt, 4 => natCmp ">" args
  | some ``GE.ge, 4 => natCmp ">=" args
  | _, _ => unsupported "condition (Prop)" p

partial def natCmp (op : String) (args : Array Expr) : TransM SExpr := do
  unless args[0]!.consumeMData.isConstOf ``Nat do unsupported "comparison on a non-Nat type" args[0]!
  judge jNatCmp
  pure (.binop op (← expr args[2]!) (← expr args[3]!))

partial def eqExpr (op : String) (ty a b : Expr) : TransM SExpr := do
  if ty.consumeMData.isConstOf ``String then
    judge jStrEq
    let r := SExpr.method (.member (← expr a) "unicodeScalars") "elementsEqual" [(none, .member (← expr b) "unicodeScalars")]
    pure (if op == "==" then r else .unop "!" r)
  else
    match ← eqInexact ty with
    | none => pure (.binop op (← expr a) (← expr b))
    | some reason =>
      let tyStr := (← ppExpr ty).pretty 100000
      throwError "elmgen: unsupported equality ({op}) on type `{tyStr}`: {reason}"

partial def lamClosure (e : Expr) : TransM SExpr := do
  judge jLambda
  lambdaTelescope e fun xs body => withNames xs do
    let mut ps := []
    for x in xs do
      ps := ps ++ [(← nameOf x, ← swiftType (← inferType x))]
    let ret ← swiftType (← inferType body)
    pure (.closure ps ret (← stmts body))

/-- Wrap a statement-only construct used in expression position. -/
partial def iife (e : Expr) : TransM SExpr := do
  judge jLet
  let ret ← swiftType (← inferType e)
  pure (.iife ret (← stmts e))

/-- Eta-expand an under-applied function `e` (constructor, app definition…) into a closure. -/
partial def etaExpand (e : Expr) : TransM SExpr := do
  judge jLambda
  let ty ← whnf (← inferType e)
  forallTelescope ty fun xs _ => withNames xs do
    if xs.isEmpty then unsupported "eta-expansion of a non-function" e
    let mut ps := []
    for x in xs do
      ps := ps ++ [(← nameOf x, ← swiftType (← inferType x))]
    let body := (mkAppN e xs).headBeta
    let ret ← swiftType (← inferType body)
    pure (.closure ps ret (← stmts body))

/-- `List.cons a (List.cons b List.nil)` → `[a, b]`; a non-nil tail becomes `[a, b] + tail`. -/
partial def listChain (e : Expr) : TransM SExpr := do
  judge jList
  let mut items : List SExpr := []
  let mut cur := e.consumeMData
  repeat
    if cur.isAppOfArity ``List.cons 3 then
      items := items ++ [← expr cur.getAppArgs[1]!]
      cur := cur.getAppArgs[2]!.consumeMData
    else break
  if cur.isAppOfArity ``List.nil 1 then
    if items.isEmpty then pure (.emptyArray (← swiftType cur.getAppArgs[0]!))
    else judge jCons; pure (.array items)
  else
    judge jCons
    pure (.binop "+" (.array items) (← expr cur))

partial def args' (xs : Array Expr) : TransM (List SExpr) := do
  let mut out := []
  for x in xs do out := out ++ [← expr x]
  pure out

/-- Whitelisted library heads.  Returns `none` when `c` is not a library primitive. -/
partial def prim (c : Name) (args : Array Expr) (e : Expr) : TransM (Option SExpr) := do
  let a (i : Nat) : TransM SExpr := expr args[i]!
  let isTy (i : Nat) (n : Name) : Bool := args[i]!.consumeMData.isConstOf n
  match c, args.size with
  | ``ite, 5 => judge jIte; pure (some (.ternary (← cond args[1]!) (← a 3) (← a 4)))
  | ``dite, 5 => unsupported "dependent if-then-else (dite)" e
  | ``OfNat.ofNat, 3 =>
    match args[1]!.consumeMData with
    | .lit (.natVal n) => if isTy 0 ``Nat then pure (some (← natLit n e)) else unsupported "numeric literal at a non-Nat type" e
    | _ => unsupported "OfNat.ofNat with a non-literal" e
  | ``HAdd.hAdd, 6 => if isTy 0 ``Nat && isTy 1 ``Nat then judge jNat; pure (some (.binop "+" (← a 4) (← a 5))) else unsupported "addition on a non-Nat type" e
  | ``HMul.hMul, 6 => if isTy 0 ``Nat && isTy 1 ``Nat then judge jNat; pure (some (.binop "*" (← a 4) (← a 5))) else unsupported "multiplication on a non-Nat type" e
  | ``HSub.hSub, 6 => if isTy 0 ``Nat && isTy 1 ``Nat then judge jNat; judge jNatSub; pure (some (.call "max" [(none, .binop "-" (← a 4) (← a 5)), (none, .raw "0")])) else unsupported "subtraction on a non-Nat type" e
  | ``HDiv.hDiv, 6 => unsupported "division (HDiv.hDiv; Lean's x / 0 = 0)" e
  | ``HMod.hMod, 6 => unsupported "modulo (HMod.hMod; Lean's x % 0 = x)" e
  | ``Nat.succ, 1 => judge jSucc; pure (some (.binop "+" (← a 0) (.raw "1")))
  | ``HAppend.hAppend, 6 =>
    if isTy 0 ``String && isTy 1 ``String then judge jAppend; pure (some (.binop "+" (← a 4) (← a 5)))
    else if args[0]!.isAppOfArity ``List 1 then judge jAppend; judge jList; pure (some (.binop "+" (← a 4) (← a 5)))
    else unsupported "append on type" args[0]!
  | ``String.append, 2 => judge jAppend; pure (some (.binop "+" (← a 0) (← a 1)))
  | ``bne, 4 => pure (some (← eqExpr "!=" args[0]! args[2]! args[3]!))
  | ``BEq.beq, 4 => pure (some (← eqExpr "==" args[0]! args[2]! args[3]!))
  | ``Bool.not, 1 => judge jBoolOps; pure (some (.unop "!" (← a 0)))
  | ``Bool.and, 2 => judge jBoolOps; pure (some (.binop "&&" (← a 0) (← a 1)))
  | ``Bool.or, 2 => judge jBoolOps; pure (some (.binop "||" (← a 0) (← a 1)))
  | ``Decidable.decide, 2 => judge jIte; pure (some (← cond args[0]!))
  | ``toString, 3 =>
    if isTy 0 ``Nat then judge jToStringNat; pure (some (.call "String" [(none, ← a 2)]))
    else if isTy 0 ``String then pure (some (← a 2))
    else if isTy 0 ``Bool then judge jToStringBool; pure (some (.ternary (← a 2) (.raw "\"true\"") (.raw "\"false\"")))
    else unsupported "toString at type" args[0]!
  | ``String.isEmpty, 1 => judge jIsEmpty; pure (some (.member (← a 0) "isEmpty"))
  | ``String.length, 1 => judge jStrLength; pure (some (.member (.member (← a 0) "unicodeScalars") "count"))
  | ``String.Slice.copy, 1 =>
    -- only the pair `(String.trimAscii s).copy` is understood (Slice is not modelled on its own)
    let inner := args[0]!.consumeMData
    if inner.isAppOfArity ``String.trimAscii 1 then
      judge jTrim
      requestShim "trimAscii"
      pure (some (.call "leanTrimAscii" [(none, ← expr inner.getAppArgs[0]!)]))
    else unsupported "String.Slice.copy of something other than String.trimAscii" e
  | ``List.map, 4 => judge jList; pure (some (.method (← a 3) "map" [(none, ← a 2)]))
  | ``List.filter, 3 => judge jList; pure (some (.method (← a 2) "filter" [(none, ← a 1)]))
  | ``List.any, 3 => judge jAny; pure (some (.method (← a 1) "contains" [(some "where", ← a 2)]))   -- list FIRST
  | ``List.all, 3 => judge jAll; pure (some (.method (← a 1) "allSatisfy" [(none, ← a 2)]))
  | ``List.length, 2 => judge jLength; pure (some (.member (← a 1) "count"))
  | ``List.isEmpty, 2 => judge jIsEmpty; pure (some (.member (← a 1) "isEmpty"))
  | ``List.reverse, 2 => judge jReverse; pure (some (.call "Array" [(none, .method (← a 1) "reversed" [])]))
  | ``List.append, 3 => judge jAppend; judge jList; pure (some (.binop "+" (← a 1) (← a 2)))
  | ``List.cons, 3 => pure (some (← listChain e))
  | ``List.nil, 1 => pure (some (← listChain e))
  | ``Option.some, 2 => judge jSome; pure (some (.call s!"Optional<{← swiftType args[0]!}>.some" [(none, ← a 1)]))
  | ``Option.none, 1 => judge jSome; pure (some (.raw s!"Optional<{← swiftType args[0]!}>.none"))
  | ``Bool.true, 0 => pure (some (.raw "true"))
  | ``Bool.false, 0 => pure (some (.raw "false"))
  | _, _ => pure none

partial def expr (e : Expr) : TransM SExpr := do
  let e := e.consumeMData
  match e with
  | .fvar _ => pure (.raw (← nameOf e))
  | .lit (.strVal s) => pure (.raw (swiftStringLit s))
  | .lit (.natVal n) => natLit n e
  | .lam .. => lamClosure e
  | .letE .. => iife e
  | .proj s i x =>
    let fields := getStructureFields (← getEnv) s
    match fields[i]? with
    | some f => pure (.member (← expr x) (sanitize f))
    | none => unsupported "projection" e
  | .mdata _ x => expr x
  | .app .. | .const .. =>
    let fn := e.getAppFn
    let args := e.getAppArgs
    match fn with
    | .lam .. => expr e.headBeta
    | .fvar _ => pure (.call (← nameOf fn) ((← args' args).map fun a => (none, a)))
    | .const c _ =>
      if let some _ ← getMatcherInfo? c then
        if let some _ ← matchMatcherApp? e then iife e
        else unsupported "partially applied matcher" e
      else if let some r ← prim c args e then pure r
      else constApp c args e
    | _ => unsupported "application head" fn
  | _ => unsupported "expression" e

/-- Application of a constant that is not a library primitive: projection, constructor or app definition. -/
partial def constApp (c : Name) (args : Array Expr) (e : Expr) : TransM SExpr := do
  let env ← getEnv
  -- recursion and recursors: structural recursion compiles to `T.brecOn`, well-founded recursion to `WellFounded.fix`
  if isAuxRecursor env c || isRecCore env c || isNoConfusion env c || c == ``WellFounded.fix || c == ``WellFounded.fixF then
    unsupported s!"recursive definition or recursor (compiled through `{c}`); recursion is not supported" e
  -- structure projection function
  if let some pinfo := env.getProjectionFnInfo? c then
    if pinfo.fromClass then unsupported s!"library class method (not in the whitelist): {c}" e
    let sName := (← getConstInfoCtor pinfo.ctorName).induct
    unless ← inAppNs sName do unsupported "projection of a non-app structure" e
    if args.size != pinfo.numParams + 1 then unsupported "projection arity (expected exactly the structure argument)" e
    let fields := getStructureFields env sName
    requestType sName
    return .member (← expr args[pinfo.numParams]!) (sanitize fields[pinfo.i]!)
  match env.find? c with
  | some (.ctorInfo ci) =>
    let ind := ci.induct
    let fieldArgs := args.extract ci.numParams args.size
    if fieldArgs.size < ci.numFields then return ← etaExpand e
    if fieldArgs.size > ci.numFields then unsupported "over-applied constructor" e
    if ind == `ElmLean.Html then
      judge jHtml
      let msgTy ← swiftType args[0]!
      let short := sanitize (c.replacePrefix `ElmLean.Html .anonymous)
      let labels ← if htmlLabeled.contains c then (← ctorFieldNames c).mapM (pure ∘ some) else pure (Array.replicate ci.numFields none)
      let mut as := []
      for i in [0:ci.numFields] do
        as := as ++ [(labels[i]!, ← expr fieldArgs[i]!)]
      return .html short msgTy as
    if ind == `ElmLean.ButtonRole || ind == `ElmLean.TextStyle then
      judge jRole
      return .raw s!"{sanitize (ind.replacePrefix `ElmLean .anonymous)}.{sanitize (c.replacePrefix ind .anonymous)}"
    unless ← inAppNs ind do unsupported "constructor of a non-app inductive" e
    requestType ind
    let tyName ← shortName ind
    let ctorShort := sanitize (c.replacePrefix ind .anonymous)
    if isStructure env ind then
      judge jStruct
      let fields := getStructureFields env ind
      let mut as := []
      for i in [0:ci.numFields] do
        as := as ++ [(some (sanitize fields[i]!), ← expr fieldArgs[i]!)]
      return .call tyName as
    else
      judge jEnum
      if ci.numFields == 0 then return .raw s!"{tyName}.{ctorShort}"
      return .call s!"{tyName}.{ctorShort}" ((← args' fieldArgs).map fun a => (none, a))
  | some (.defnInfo di) =>
    unless ← inAppNs c do unsupported "library function (not in the whitelist)" (mkConst c)
    requestDef c
    let arity ← explicitArity di.type
    if args.size < arity then return ← etaExpand e
    if args.size > arity then unsupported "over-applied app definition" e
    let f ← shortName c
    return .helper f (← args' args) (← retHtmlOf di.type)
  | some _ => unsupported "constant kind (not a definition or constructor)" (mkConst c)
  | none => unsupported "unknown constant" (mkConst c)

/-- Hoist non-variable discriminants into `let`s (so variable patterns can refer to them). -/
partial def hoistDiscrs (ds : Array Expr) (i : Nat) (acc : Array Expr) (pre : List SStmt)
    (k : Array Expr → List SStmt → TransM (List SStmt)) : TransM (List SStmt) := do
  if h : i < ds.size then
    let d := ds[i].consumeMData
    if d.isFVar then hoistDiscrs ds (i+1) (acc.push d) pre k
    else
      let v ← expr d
      withLocalDecl `d .default (← inferType d) fun x => withNames #[x] do
        hoistDiscrs ds (i+1) (acc.push x) (pre ++ [.letS (← nameOf x) v]) k
  else k acc pre

/-- The pattern variables (fields of the alternative) occurring in pattern `p`, in order; throws on
every pattern shape that has no Swift pattern (structures, Nat / String literals, nested lists, …). -/
partial def collectPatVars (p : Expr) (zs : Array Expr) : TransM (Array Expr) := do
  let p := p.consumeMData
  if p.isFVar && zs.contains p then return #[p]
  if p.isLit then unsupported "literal pattern" p
  let fn := p.getAppFn
  let args := p.getAppArgs
  match fn.constName? with
  | some ``Bool.true | some ``Bool.false => pure #[]
  | some ``Option.none => pure #[]
  | some ``Option.some => collectPatVars args[1]! zs
  | some ``List.nil | some ``List.cons => unsupported "nested List pattern" p
  | some cn =>
    let env ← getEnv
    match env.find? cn with
    | some (.ctorInfo ci) =>
      if ci.induct == ``Nat then unsupported "Nat literal pattern" p
      unless ← inAppNs ci.induct do unsupported s!"pattern on a non-app inductive ({ci.induct})" p
      if isStructure env ci.induct then unsupported "structure pattern" p
      let mut acc := #[]
      for f in args.extract ci.numParams args.size do acc := acc ++ (← collectPatVars f zs)
      pure acc
    | _ =>
      if cn == ``OfNat.ofNat then unsupported "Nat literal pattern" p
      unsupported "non-constructor pattern head" p
  | none => unsupported "pattern" p

/-- The Swift pattern for `p` (after `withNames` bound its variables); unused variables print as `_`. -/
partial def printPat (p : Expr) (zs : Array Expr) (body : Expr) : TransM String := do
  let p := p.consumeMData
  if p.isFVar && zs.contains p then
    let nm ← nameOf p
    return if body.containsFVar p.fvarId! then s!"let {nm}" else "_"
  let fn := p.getAppFn
  let args := p.getAppArgs
  match fn.constName? with
  | some ``Bool.true => judge jNested; pure "true"
  | some ``Bool.false => judge jNested; pure "false"
  | some ``Option.none => judge jNested; pure s!"Optional<{← swiftType args[0]!}>.none"
  | some ``Option.some => judge jNested; pure s!"Optional<{← swiftType args[0]!}>.some({← printPat args[1]! zs body})"
  | some cn =>
    let some (.ctorInfo ci) := (← getEnv).find? cn | unsupported "non-constructor pattern head" p
    requestType ci.induct
    let tyName ← shortName ci.induct
    let ctorShort := sanitize (cn.replacePrefix ci.induct .anonymous)
    let fields := args.extract ci.numParams args.size
    if fields.isEmpty then return s!"{tyName}.{ctorShort}"
    let mut subs : List String := []
    for f in fields do
      let s ← printPat f zs body
      if !(f.consumeMData.isFVar && zs.contains f.consumeMData) then judge jNested
      subs := subs ++ [s]
    pure s!"{tyName}.{ctorShort}({", ".intercalate subs})"
  | none => unsupported "pattern" p

/-- One matcher alternative: recover its patterns from the alternative's TYPE (`∀ fields, motive p₁ … pₙ`),
bind the same fvars in the alternative's body (`alt.beta zs`), substitute variable patterns by the
discriminant, and translate the body.  Returns (pattern per discriminant, body statements). -/
partial def transAlt (altTy alt : Expr) (discrs : Array Expr) : TransM (Array Pat × List SStmt) := do
  let nD := discrs.size
  forallTelescope altTy fun zs res => do
    let pats := res.getAppArgs
    unless res.getAppFn.isFVar && pats.size == nD do unsupported "matcher alternative result" res
    let mut body := alt.beta zs
    let mut kinds : Array (Option Expr) := #[]   -- `none` = variable pattern
    let mut bound : Array Expr := #[]
    for j in [0:nD] do
      let p := pats[j]!.consumeMData
      if p.isFVar && zs.contains p then
        body := body.replaceFVar p discrs[j]!
        kinds := kinds.push none
      else
        if isListPat p then
          unless nD == 1 do unsupported "List pattern in a match on several discriminants" p
          for f in p.getAppArgs.extract 1 p.getAppArgs.size do
            unless f.consumeMData.isFVar && zs.contains f.consumeMData do unsupported "nested List pattern" p
            bound := bound.push f.consumeMData
        else
          bound := bound ++ (← collectPatVars p zs)
        kinds := kinds.push (some p)
    -- Unit dummies (`fun _ : Unit => …`) are fine; anything else unaccounted for is not.
    for z in zs do
      unless bound.contains z || pats.contains z do
        unless (← inferType z).isConstOf ``Unit do unsupported "matcher alternative parameter (equation/dependent)" z
    withNames bound do
      let mut out : Array Pat := #[]
      for k in kinds do
        match k with
        | none => out := out.push .var
        | some p =>
          if p.isAppOfArity ``List.nil 1 then out := out.push .listNil
          else if p.isAppOfArity ``List.cons 3 then
            let fs := p.getAppArgs.extract 1 3
            let nm (f : Expr) : TransM (Option String) := do
              let f := f.consumeMData
              if body.containsFVar f.fvarId! then pure (some (← nameOf f)) else pure none
            out := out.push (.listCons (← nm fs[0]!) (← nm fs[1]!))
          else out := out.push (.swift (← printPat p zs body))
      pure (out, ← stmts body)

/-- `match` compiled to an auxiliary matcher → Swift `switch` (patterns come from the matcher's type),
or an `if xs.isEmpty` chain for a match on a List. -/
partial def transMatch (ma : MatcherApp) : TransM (List SStmt) := do
  unless ma.remaining.isEmpty do unsupported "matcher applied to extra arguments" (mkAppN (mkConst ma.matcherName) ma.remaining)
  unless ma.params.isEmpty do unsupported "matcher with parameters" (mkConst ma.matcherName)
  judge jMatch
  let mci ← getConstInfo ma.matcherName
  let mty := mci.type.instantiateLevelParams mci.levelParams ma.matcherLevels.toList
  let nD := ma.discrs.size
  hoistDiscrs ma.discrs 0 #[] [] fun discrs pre => do
    let alts ← forallTelescope mty fun ys _ => do
      let base := ys.size - ma.alts.size
      let mut alts : Array (Array Pat × List SStmt) := #[]
      for i in [0:ma.alts.size] do
        alts := alts.push (← transAlt (← inferType ys[base + i]!) ma.alts[i]! discrs)
      pure alts
    if alts.any (fun (ps, _) => ps.any Pat.isList) then
      -- single discriminant of type List: rows are tried in order, so the first row that matches `[]`
      -- (a `[]` row or a wildcard) and the first row that matches `h :: t` are the two branches
      judge jListPat
      let xs ← nameOf discrs[0]!
      let some (_, nilBody) := alts.find? (fun (ps, _) => match ps[0]! with | .listNil | .var => true | _ => false)
        | unsupported "List match without a [] or wildcard row" (mkConst ma.matcherName)
      let some (cps, consBody) := alts.find? (fun (ps, _) => match ps[0]! with | .listCons .. | .var => true | _ => false)
        | unsupported "List match without a h :: t or wildcard row" (mkConst ma.matcherName)
      let binds : List SStmt := match cps[0]! with
        | .listCons h t =>
          (h.map fun h => SStmt.letS h (.raw s!"{xs}[0]")).toList ++
          (t.map fun t => SStmt.letS t (.call "Array" [(none, .method (.raw xs) "dropFirst" [])])).toList
        | _ => []
      return pre ++ [.ite (.member (.raw xs) "isEmpty") nilBody (binds ++ consBody)]
    let ctorIdx := (List.range nD).filter fun j => alts.any fun (ps, _) => match ps[j]! with | .swift _ => true | _ => false
    match ctorIdx with
    | [] =>
      unless alts.size == 1 do unsupported "matcher without constructor patterns but several alternatives" (mkConst ma.matcherName)
      pure (pre ++ alts[0]!.2)
    | [j] =>
      let scrut ← expr discrs[j]!
      let cases := alts.toList.map fun (ps, body) => ((ps[j]!).text, body)
      pure (pre ++ [.switch scrut cases])
    | js =>
      let mut scruts := []
      for j in js do scruts := scruts ++ [← expr discrs[j]!]
      let scrut := SExpr.raw ("(" ++ ", ".intercalate (scruts.map (·.print {} 0)) ++ ")")
      let cases := alts.toList.map fun (ps, body) => ("(" ++ ", ".intercalate (js.map fun j => (ps[j]!).text) ++ ")", body)
      pure (pre ++ [.switch scrut cases])

end

/-! ## Declarations -/

def docOf (n : Name) : TransM (Option String) := do
  let d ← findDocString? (← getEnv) n
  if d.isSome then judge jDoc
  pure d

def emitDef (n : Name) : TransM DefIR := do
  let some (.defnInfo di) := (← getEnv).find? n | unsupported "non-definition" (mkConst n)
  unless di.levelParams.isEmpty do unsupported "universe-polymorphic definition" (mkConst n)
  let f ← shortName n
  let doc ← docOf n
  let retHtml ← retHtmlOf di.type
  lambdaTelescope di.value fun xs body0 => do
    -- extra arrows not written as lambdas
    let bodyTy ← inferType body0
    forallTelescope bodyTy fun ys _ => do
      let params := xs ++ ys
      for x in params do
        if (← x.fvarId!.getDecl).binderInfo != .default then unsupported "implicit parameter" (mkConst n)
      withNames params do
        let body := (mkAppN body0 ys).headBeta
        let ret ← swiftType (← inferType body)
        let ss ← stmts body
        let mut ps := []
        for x in params do ps := ps ++ [(← nameOf x, ← swiftType (← inferType x))]
        pure { leanName := n, swiftName := f, doc, params := ps, ret, retHtml, body := ss }

def emitType (n : Name) : TransM TypeIR := do
  let env ← getEnv
  let some (.inductInfo ind) := env.find? n | unsupported "non-inductive type" (mkConst n)
  unless ind.numParams == 0 && ind.numIndices == 0 do unsupported "parameterized/indexed inductive" (mkConst n)
  let tyName ← shortName n
  let doc ← docOf n
  let decEq ← hasDecEq (mkConst n)
  let inexact ← eqInexact (mkConst n)
  let equatable := decEq && inexact.isNone
  if equatable then judge s!"`{tyName}`: Lean DecidableEq → Swift Equatable (the synthesized == is exact for its fields)"
  else if decEq then judge s!"`{tyName}`: Lean has DecidableEq but Swift gets no Equatable ({inexact.getD ""}); comparing its values is rejected"
  else judge s!"`{tyName}`: no Lean DecidableEq, so no Swift Equatable; comparing its values is rejected"
  if isStructure env n then
    judge jStruct
    let ctor ← getConstInfoCtor ind.ctors.head!
    let fields := getStructureFields env n
    let fieldTys ← forallTelescope ctor.type fun xs _ => xs.mapM fun x => do swiftType (← inferType x)
    let mut fs := []
    for i in [0:fields.size] do
      fs := fs ++ [(sanitize fields[i]!, fieldTys[i]!, ← docOf (n ++ fields[i]!))]
    pure { leanName := n, swiftName := tyName, doc, equatable, body := .struct fs }
  else
    judge jEnum
    let mut cases := []
    for c in ind.ctors do
      let ci ← getConstInfoCtor c
      let short := sanitize (c.replacePrefix n .anonymous)
      let tys ← forallTelescope ci.type fun xs _ => (xs.extract ci.numParams xs.size).mapM fun x => do swiftType (← inferType x)
      cases := cases ++ [(short, tys.toList, ← docOf c)]
    if ind.isRec then judge jIndirect
    pure { leanName := n, swiftName := tyName, doc, equatable, body := .enum ind.isRec cases }

partial def drain : TransM Unit := do
  let st ← get
  if let some d := st.pendingDefs[0]? then
    modify fun s => { s with pendingDefs := s.pendingDefs.eraseIdx! 0, doneDefs := s.doneDefs.insert d }
    let ir ← emitDef d
    modify fun s => { s with defs := s.defs.push ir }
    drain
  else if let some t := st.pendingTypes[0]? then
    modify fun s => { s with pendingTypes := s.pendingTypes.eraseIdx! 0, doneTypes := s.doneTypes.insert t }
    let ir ← emitType t
    modify fun s => { s with types := s.types.push ir }
    drain

partial def withLocals (binders : Array (Name × Expr)) (i : Nat) (acc : Array Expr) (k : Array Expr → TransM α) : TransM α := do
  if h : i < binders.size then
    withLocalDecl binders[i].1 .default binders[i].2 fun x => withLocals binders (i+1) (acc.push x) k
  else k acc

/-- Protocol member for an `App` field: nothing to add when the field IS an app definition whose Swift
name already matches (`update`, `view`); otherwise a member wrapping the field expression.  Either way
the member name is claimed, so a helper that would also print as `update` is a translation-time error. -/
def emitProtocolMember (member : String) (field : Expr) (arity : Nat) (paramTys : Array Expr) (retTy : Expr) :
    TransM (Option DefIR) := do
  let field := field.consumeMData
  let pseudo := `ElmApp ++ Name.mkSimple member
  if let .const c _ := field then
    if ← inAppNs c then
      if (← shortName c) == member then
        let a ← explicitArity (← getConstInfo c).type
        if a == arity then
          requestDef c
          return none
  claimName member pseudo s!"the `ElmApp` member `{member}` (wrapping `{field}`)"
  let retHtml := retTy.consumeMData.isAppOf `ElmLean.Html
  if arity == 0 then
    let ss ← stmts field
    return some { leanName := pseudo, swiftName := member, params := [], ret := ← swiftType retTy, retHtml, body := ss }
  let mut binders : Array (Name × Expr) := #[]
  for i in [0:arity] do binders := binders.push (Name.mkSimple s!"a{i}", paramTys[i]!)
  withLocals binders 0 #[] fun xs => withNames xs do
    let body := (mkAppN field xs).headBeta
    let ss ← stmts body
    let mut ps := []
    for x in xs do ps := ps ++ [(← nameOf x, ← swiftType (← inferType x))]
    pure (some { leanName := pseudo, swiftName := member, params := ps, ret := ← swiftType retTy, retHtml, body := ss })

partial def codecOf (t : Expr) (acc : Array Name) : TransM (Codec × Array Name) := do
  match t.consumeMData with
  | .const `Nat _ => pure (.nat, acc)
  | .const `String _ => pure (.str, acc)
  | .const `Bool _ => pure (.bool, acc)
  | .app (.const `List _) a => let (c, acc) ← codecOf a acc; pure (.list c, acc)
  | .app (.const `Option _) a => let (c, acc) ← codecOf a acc; pure (.opt c, acc)
  | .const n _ =>
    unless ← inAppNs n do unsupported "type in a command or host answer (not an app type)" t
    let some (.inductInfo _) := (← getEnv).find? n | unsupported "type in a command or host answer" t
    pure (.named (← shortName n), if acc.contains n then acc else acc.push n)
  | _ => unsupported "type in a command or host answer" t

/-- Codecs for `roots` and every app type their fields reach. -/
partial def codecClosure (roots : Array Name) : TransM (Array CodecIR) := do
  let mut todo := roots
  let mut done : Array Name := #[]
  let mut out : Array CodecIR := #[]
  while h : 0 < todo.size do
    let n := todo[0]
    todo := todo.eraseIdx 0
    if done.contains n then continue
    done := done.push n
    let env ← getEnv
    let some (.inductInfo ind) := env.find? n | unsupported "non-inductive type" (mkConst n)
    let mut found : Array Name := #[]
    if isStructure env n then
      let ctor ← getConstInfoCtor ind.ctors.head!
      let fields := getStructureFields env n
      let tys ← forallTelescope ctor.type fun xs _ => xs.mapM fun x => inferType x
      let mut fs := []
      for i in [0:fields.size] do
        let (c, f') ← codecOf tys[i]! found
        found := f'
        fs := fs ++ [(fields[i]!.toString, sanitize fields[i]!, c)]
      out := out.push { swiftName := ← shortName n, body := .struct fs }
    else
      let mut cases := []
      for c in ind.ctors do
        let ci ← getConstInfoCtor c
        let tag := (c.replacePrefix n .anonymous).toString
        let fieldNames ← forallTelescope ci.type fun xs _ =>
          (xs.extract ci.numParams xs.size).mapM fun x => do pure ((← x.fvarId!.getDecl).userName.toString, ← inferType x)
        let mut ps := []
        for (k, ty) in fieldNames do
          let (cd, f') ← codecOf ty found
          found := f'
          ps := ps ++ [(k, cd)]
        cases := cases ++ [(tag, sanitize (c.replacePrefix n .anonymous), ps)]
      out := out.push { swiftName := ← shortName n, body := .enum cases }
    for f in found do
      unless done.contains f do todo := todo.push f
  pure out

/-- Translate everything reachable from the `App Model Msg` constant `appConst`. -/
def translateApp (appConst : Name) (appName screenName : String) : MetaM GenResult := do
  let ci ← getConstInfoDefn appConst
  let v0 := ci.value.consumeMData
  -- an app with commands is `CmdApp.mk Model Msg Cmd Host (App.mk …) cmds host`
  let (v, cmdArgs) :=
    if v0.isAppOfArity `ElmLean.CmdApp.mk 7 then
      let a := v0.getAppArgs
      (a[4]!.consumeMData, some (a[2]!, a[3]!, a[5]!, a[6]!))
    else (v0, none)
  unless v.isAppOfArity `ElmLean.App.mk 5 do
    throwError "elmgen: {appConst} is not literally an `App.mk` (or `CmdApp.mk`) application: {← showExpr v0}"
  let args := v.getAppArgs
  let modelTy := args[0]!
  let msgTy := args[1]!
  let appNs := appConst.getPrefix
  let env ← getEnv
  -- local variables must never shadow an app definition: seed the used-name list with every app
  -- constant's Swift short name (helpers are discovered lazily, after locals have been named)
  let appShort := env.constants.fold (init := reservedLocalNames) fun acc n _ =>
    if appNs.isPrefixOf n && n != appNs && !n.isInternal then sanitize (n.replacePrefix appNs .anonymous) :: acc else acc
  let ctx : Ctx := { appNs, appName, screenName, used := appShort }
  let act : TransM GenResult := do
    let mut members : Array DefIR := #[]
    if let some d ← emitProtocolMember "initial" args[2]! 0 #[] modelTy then members := members.push d
    if let some d ← emitProtocolMember "update" args[3]! 2 #[msgTy, modelTy] modelTy then members := members.push d
    if let some d ← emitProtocolMember "view" args[4]! 1 #[modelTy] (mkApp (mkConst `ElmLean.Html) msgTy) then members := members.push d
    let mut cmd : Option CmdGen := none
    if let some (cmdTy, hostTy, cmdsF, hostF) := cmdArgs then
      judge jCmdApp
      if let some d ← emitProtocolMember "cmds" cmdsF 2 #[msgTy, modelTy] (mkApp (mkConst `List [.zero]) cmdTy) then
        members := members.push d
      if let some d ← emitProtocolMember "host" hostF 1 #[hostTy] msgTy then members := members.push d
      let cmdSwift ← swiftType cmdTy
      let hostSwift ← swiftType hostTy
      let roots ← [cmdTy, hostTy].toArray.mapM fun t => do
        match t.consumeMData with
        | .const n _ => pure n
        | _ => unsupported "command or host type (must be an app inductive)" t
      judge jCodec
      cmd := some { cmdType := cmdSwift, hostType := hostSwift, codecs := ← codecClosure roots }
    -- make sure the two app types exist even if nothing referenced them
    let _ ← swiftType modelTy
    let _ ← swiftType msgTy
    drain
    let st ← get
    pure { appConst, appName, screenName, types := st.types, defs := st.defs, members,
           shims := st.shims, judgments := st.judgments, cmd }
  (act.run ctx).run' {}

end ElmGen
