import LeanNativeShell.Manifest

/-! Simple's Xcode project: `lake exe ios-project` writes its XcodeGen spec (framework/native/ci/build-ios runs
it). The app never imports this module, so none of it is in the app. -/

open LeanNativeShell

def manifest : Manifest where
  name := "Simple"
  displayName := "Simple"
  bundleId := "art.fralex.leannative.simple"
  -- the only capability the app calls: the shell gets no other, and links no framework it would need
  uses := ["open"]
  -- the journey only: the test kit's driver, no Objective-C tests of its own
  uiTests := some { sources := [] }

def main := manifest.main
