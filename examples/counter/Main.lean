import ElmLean.Cli
import Counter.App

def main (args : List String) : IO UInt32 :=
  ElmLean.Cli.main Counter.app args
