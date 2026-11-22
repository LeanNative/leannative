import Lean
import LeanNative.Tag

/-! # `deriving LeanNative.Tag`

Compile-time only: it imports `Lean`, so the iOS app never imports this module; a journeys executable or a test
does, and derives the tags there (`deriving instance LeanNative.Tag for HomeMsg, Msg`). For each constructor the
tag is its name; when one of its fields has a `Tag` instance already (a message type derived before it,
`Except`, `Option`), the first such field's tag follows after a dot, and `all` lists every combination. A field
whose type depends on another field is not looked into. Plain types only: no parameters, no indices. -/

namespace LeanNative.TagDeriving
open Lean Elab Command Term Meta
open Lean.Parser.Term

/-- Each constructor: its name, how many fields it has, and the position and type of its first tagged field. -/
private def plan (indVal : InductiveVal) : TermElabM (Array (Name × Nat × Option (Nat × Term))) :=
  indVal.ctors.toArray.mapM fun ctorName => do
    let info ← getConstInfoCtor ctorName
    forallTelescopeReducing info.type fun xs _ => do
      let mut tagged : Option (Nat × Term) := none
      for i in [0:info.numFields] do
        if tagged.isNone then
          let ty ← inferType xs[indVal.numParams + i]!
          unless ty.hasFVar do
            if (← synthInstance? (← mkAppM ``LeanNative.Tag #[ty])).isSome then
              let stx ← withOptions (fun o => o.setBool `pp.fullNames true) (PrettyPrinter.delab ty)
              tagged := some (i, stx)
      return (ctorName, info.numFields, tagged)

private def mkInstance (indName : Name) : TermElabM Command := do
  let indVal ← getConstInfoInduct indName
  if indVal.numParams != 0 || indVal.numIndices != 0 then
    throwError "deriving LeanNative.Tag: {indName} has parameters or indices; only plain types are tagged"
  if indVal.ctors.isEmpty then
    throwError "deriving LeanNative.Tag: {indName} has no constructors"
  let a := mkIdent `a
  let mut alts : Array (TSyntax ``matchAlt) := #[]
  let mut all : Term ← `((#[] : Array String))
  for (ctorName, fields, tagged) in ← plan indVal do
    let name := Syntax.mkStrLit ctorName.getString!
    let args ← (List.range fields).toArray.mapM fun i =>
      if tagged.map (·.1) == some i then pure (a : Term) else `(_)
    let pat ← `(@$(mkIdent ctorName):ident $args:term*)
    match tagged with
    | none =>
      alts := alts.push (← `(matchAltExpr| | $pat:term => $name:str))
      all ← `($all |>.push $name:str)
    | some (_, ty) =>
      alts := alts.push (← `(matchAltExpr| | $pat:term => $name:str ++ "." ++ LeanNative.Tag.tag $a:ident))
      all ← `($all ++ (LeanNative.Tag.all (α := $ty)).map (fun s => $name:str ++ "." ++ s))
  `(instance : LeanNative.Tag $(mkIdent indName) where
      tag x := match x with $alts:matchAlt*
      all := $all)

def mkTagHandler (declNames : Array Name) : CommandElabM Bool := do
  unless ← declNames.allM isInductive do return false
  for declName in declNames do
    elabCommand (← liftTermElabM (mkInstance declName))
  return true

initialize registerDerivingHandler ``LeanNative.Tag mkTagHandler

end LeanNative.TagDeriving
