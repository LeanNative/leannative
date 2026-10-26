import ElmLean.Gate
import __Name__.Proofs

-- One line per theorem you advertise; the scan below covers every other theorem in the closure.
#assert_axioms __Name__.count_inc
#assert_axioms __Name__.update_inv
#assert_axioms __Name__.run_inv

#assert_all_axioms ElmLean __Name__
