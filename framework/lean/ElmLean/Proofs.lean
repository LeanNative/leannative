import ElmLean.Gate
import ElmLean.Cli
import ElmLean.Proofs.Erase
import ElmLean.Proofs.Sat
import ElmLean.Proofs.Program
import ElmLean.Proofs.Spec

/-! The framework's own axiom gate: the generic theorems every app relies on. See `ElmLean.Gate`
for what the two commands check, and `framework/scripts/check-axioms.sh` for the log checks. -/

-- erasure and satisfaction: what the wire advertises is exactly what dispatches
#assert_axioms ElmLean.Html.advertises_iff
#assert_axioms ElmLean.Html.Sat.dispatch
#assert_axioms ElmLean.Html.Sat.of_forall
-- the protocol step, for any app
#assert_axioms ElmLean.Session.handle_advertised
#assert_axioms ElmLean.Session.handle_dispatch
#assert_axioms ElmLean.Session.start_coherent
#assert_axioms ElmLean.Session.handle_coherent
#assert_axioms ElmLean.Session.run_coherent
#assert_axioms ElmLean.Session.handle_inv
#assert_axioms ElmLean.Session.run_inv
#assert_axioms ElmLean.Session.reach_coherent
-- what a `Spec` buys every app
#assert_axioms ElmLean.Spec.reachable_inv
#assert_axioms ElmLean.Spec.reachable_sound

#assert_all_axioms ElmLean
