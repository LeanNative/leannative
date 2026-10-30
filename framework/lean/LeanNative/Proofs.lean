import LeanNative.Gate
import LeanNative.Cli
import LeanNative.Proofs.Erase
import LeanNative.Proofs.Sat
import LeanNative.Proofs.Program
import LeanNative.Proofs.Spec
import LeanNative.Proofs.Cmd

/-! The framework's own axiom gate: the generic theorems every app relies on. See `LeanNative.Gate`
for what the two commands check, and `framework/scripts/check-axioms.sh` for the log checks. -/

-- erasure and satisfaction: what the wire advertises is exactly what dispatches
#assert_axioms LeanNative.Html.advertises_iff
#assert_axioms LeanNative.Html.Sat.dispatch
#assert_axioms LeanNative.Html.Sat.of_forall
-- the protocol step, for any app
#assert_axioms LeanNative.Session.handle_advertised
#assert_axioms LeanNative.Session.handle_dispatch
#assert_axioms LeanNative.Session.start_coherent
#assert_axioms LeanNative.Session.handle_coherent
#assert_axioms LeanNative.Session.run_coherent
#assert_axioms LeanNative.Session.handle_inv
#assert_axioms LeanNative.Session.run_inv
#assert_axioms LeanNative.Session.reach_coherent
-- what a `Spec` buys every app
#assert_axioms LeanNative.Spec.reachable_inv
#assert_axioms LeanNative.Spec.reachable_sound
-- apps with commands: where every message comes from, over any interleaving of events and host answers
#assert_axioms LeanNative.Session.handle_accept
#assert_axioms LeanNative.Session.step_origin
#assert_axioms LeanNative.Session.step_coherent
#assert_axioms LeanNative.Session.runC_coherent
#assert_axioms LeanNative.Session.runC_inv
#assert_axioms LeanNative.Session.accept_sat
#assert_axioms LeanNative.Session.trace_getElem?
#assert_axioms LeanNative.Session.runC_take_succ
#assert_axioms LeanNative.CmdApp.reach_coherent
#assert_axioms LeanNative.CmdSpec.reachable_inv
#assert_axioms LeanNative.CmdSpec.trace_origin

#assert_all_axioms LeanNative
