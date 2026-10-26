import Todo.Selftest

def main (args : List String) : IO UInt32 :=
  ElmLean.Cli.main Todo.app args Todo.Selftest.options
