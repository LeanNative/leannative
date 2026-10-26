import ElmLean.Gate
import Todo.Proofs.Session

/-! The Todo app's axiom gate. `#assert_all_axioms ElmLean Todo` also re-scans every framework
theorem in this import closure. Run through `framework/scripts/check-axioms.sh . Todo/Gate.lean`. -/

-- the todo invariant and the effect lemmas
#assert_axioms Todo.init_inv
#assert_axioms Todo.update_inv
#assert_axioms Todo.setDone_idem
#assert_axioms Todo.setDone_ids
#assert_axioms Todo.setDone_titles
#assert_axioms Todo.setDone_mem_target
#assert_axioms Todo.setDone_target_done
#assert_axioms Todo.setDone_mem_other
#assert_axioms Todo.setDone_mem_other'
#assert_axioms Todo.delete_mem_iff
#assert_axioms Todo.delete_length
-- the todo view
#assert_axioms Todo.countToggles_view
#assert_axioms Todo.toggleLabels_view
#assert_axioms Todo.delete_dispatch
#assert_axioms Todo.toggle_dispatch
#assert_axioms Todo.add_enabled_iff
#assert_axioms Todo.footer_text
#assert_axioms Todo.view_sat
#assert_axioms Todo.view_sound
-- the framework's session theorems applied to the todo app
#assert_axioms Todo.todo_start_inv
#assert_axioms Todo.todo_handle_inv
#assert_axioms Todo.todo_run_inv
#assert_axioms Todo.todo_advertised_ok
#assert_axioms Todo.todo_reachable_sound

#assert_all_axioms ElmLean Todo
