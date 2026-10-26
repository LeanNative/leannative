-- Library root of the Todo example: the app, its proofs, its self-test script, and its axiom gate
-- (importing the gate here makes `lake build` fail on any disallowed axiom).
import Todo.App
import Todo.Proofs.Session
import Todo.Selftest
import Todo.Gate
