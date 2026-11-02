import LeanNativeShell.Manifest

/-! The Bluetooth and authentication example's Xcode project: `lake exe ios-project` writes its XcodeGen spec
(framework/native/ci/build-ios runs it). The app never imports this module, so none of it is in the app. -/

open LeanNativeShell

def manifest : Manifest where
  name := "BluetoothAuth"
  displayName := "Heart Rate"
  bundleId := "art.fralex.leannative.bluetoothauth"
  -- what the app calls: the shell gets these (and links LocalAuthentication and CoreBluetooth) and no other
  uses := ["auth", "ble.*", "keychain.*", "build"]
  usage := [
    ("NSFaceIDUsageDescription", "Your heart rate stays behind Face ID."),
    ("NSBluetoothAlwaysUsageDescription", "Connects to your heart-rate sensor.")]
  -- the journey only: the test kit's driver, no Objective-C tests of its own
  uiTests := some { sources := [] }

def main := manifest.main
