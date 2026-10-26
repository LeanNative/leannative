import Lean.Elab.Command
import Lean.Util.CollectAxioms

/-! # The axiom gate commands

Every ElmLean package (the framework itself and every app) ends its proofs with a gate file:

    import ElmLean.Gate
    import MyApp.Proofs
    #assert_axioms MyApp.update_inv          -- one line per theorem you advertise
    #assert_all_axioms ElmLean MyApp         -- every theorem under these root namespaces

* `#assert_axioms <name>` gates one named theorem: it may depend on nothing beyond the three
  standard axioms (`propext`, `Quot.sound`, `Classical.choice`). It logs one line
  `<name> OK, axioms: [...]`; `framework/scripts/check-axioms.sh` counts those lines against the
  number of `#assert_axioms` lines in the gate file.
* `#assert_all_axioms <ns>…` scans the whole environment: every `theorem` whose root namespace is one
  of the given ones, hand-written or auto-generated (equation lemmas, `injEq`, `sizeOf_spec`, …),
  gets the same check whether or not it is named. It logs exactly one line
  `all theorems OK: <k> checked under <ns>, …`, which the script also requires.

A `sorry` elaborates to the axiom `sorryAx`, which neither command allows. What that covers:

* Scanned: every theorem under the given namespaces that is in the environment at the scan line,
  i.e. in the gate file's import closure or above that line. A `sorry` in any of them, or in a
  definition one of them unfolds, makes the gate file fail to elaborate, and with it `lake build`
  when the package's root module imports the gate.
* Not scanned: a `sorry` in a `def`, `opaque` or `instance` that no scanned theorem depends on, a
  theorem below the scan line, and a theorem outside the given namespaces. Those still build; only
  `check-axioms.sh`'s quote-agnostic grep of the build log for the "declaration uses `sorry`"
  warning catches them (Lean 4.35 prints backticks).
* Not built: a file outside the package root's import closure is never elaborated, so no layer,
  grep included, sees it. -/

namespace ElmLean.Gate
open Lean

def allowedAxioms : Array Name := #[``propext, ``Quot.sound, ``Classical.choice]

end ElmLean.Gate

open Lean Elab Command in
elab "#assert_axioms " id:ident : command => do
  let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo id
  let axs ← liftCoreM <| collectAxioms n
  for a in axs do
    unless ElmLean.Gate.allowedAxioms.contains a do throwError "{n} depends on disallowed axiom {a}"
  logInfo m!"{n} OK, axioms: {axs.toList}"

open Lean Elab Command in
elab "#assert_all_axioms" nss:ident+ : command => do
  let roots : Array Name := nss.map (·.getId)
  let env ← getEnv
  -- `SMap.fold` visits both stages of the constant map (imported constants and this file's);
  -- a private name is judged by its user name
  let thms : Array Name := env.constants.fold (init := #[]) fun acc n ci =>
    match ci with
    | .thmInfo _ => if roots.contains (privateToUserName n).getRoot then acc.push n else acc
    | _ => acc
  let thms := thms.qsort Name.lt
  let mut offenders : Array String := #[]
  for n in thms do
    let axs ← liftCoreM <| collectAxioms n
    for a in axs do
      unless ElmLean.Gate.allowedAxioms.contains a do offenders := offenders.push s!"{n} depends on {a}"
  let where_ := ", ".intercalate (roots.toList.map toString)
  unless offenders.isEmpty do
    throwError "disallowed axiom in {offenders.size} theorem(s) under {where_}: {offenders.toList}"
  logInfo m!"all theorems OK: {thms.size} checked under {where_}"
