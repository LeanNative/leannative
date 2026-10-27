import Send.Selftest

def main (args : List String) : IO UInt32 :=
  ElmLean.CmdCli.main Send.app args Send.Selftest.options
