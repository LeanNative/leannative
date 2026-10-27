import ElmLean.Gate
import Send.Proofs

/-! The Send example's axiom gate: the advertised theorems, then every theorem under `ElmLean` and
`Send` (see `ElmLean.Gate`). -/

-- what the checks mean
#assert_axioms Send.authorizes_iff
#assert_axioms Send.sameOuts_iff
#assert_axioms Send.sameStrs_iff
#assert_axioms Send.matchesForm_iff
-- one step: invariant, commands, screens, the view
#assert_axioms Send.update_inv
#assert_axioms Send.sign_mem
#assert_axioms Send.broadcast_mem
#assert_axioms Send.signing_from
#assert_axioms Send.view_sat
#assert_axioms Send.reviewView_shows
#assert_axioms Send.reviewView_approve
#assert_axioms Send.sats_inj
-- every run: what you approve is what gets signed, and only that is broadcast
#assert_axioms Send.sign_approved
#assert_axioms Send.signing_has_sign
#assert_axioms Send.broadcast_approved

#assert_all_axioms ElmLean Send
