import ElmLean.Cli
import __Name__.App

/-- `__name__-cli [serve|view|selftest]`. Pass `{ check := …, script := … }` as a fourth argument to
add a runtime invariant check and a scripted self-test (see examples/todo/Todo/Selftest.lean). -/
def main (args : List String) : IO UInt32 :=
  ElmLean.Cli.main __Name__.app args
