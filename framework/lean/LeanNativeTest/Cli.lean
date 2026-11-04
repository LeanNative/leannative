import LeanNativeTest.CliApp

/-! `cli-test-app`: `LeanNativeTest.CliApp.list` on `LeanNative.Cli.main` (`make check`'s protocol target). -/

def main (args : List String) : IO UInt32 :=
  LeanNative.Cli.main LeanNativeTest.CliApp.list args LeanNativeTest.CliApp.listOptions
