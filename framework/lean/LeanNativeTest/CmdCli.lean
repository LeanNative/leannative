import LeanNativeTest.CliApp

/-! `cmdcli-test-app`: `LeanNativeTest.CliApp.saving` on `LeanNative.CmdCli.main` (`make check`'s protocol
target). -/

def main (args : List String) : IO UInt32 :=
  LeanNative.CmdCli.main LeanNativeTest.CliApp.saving args LeanNativeTest.CliApp.savingOptions
