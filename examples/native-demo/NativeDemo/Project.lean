import ElmShell.Manifest

/-! native-demo's Xcode project: `lake exe ios-project` writes its XcodeGen spec (framework/native/ci/build-ios
runs it). The app never imports this module, so none of it is in the app. -/

open ElmShell

def manifest : Manifest where
  name := "NativeDemo"
  displayName := "Native Demo"
  bundleId := "art.fralex.elmlean.nativedemo"
  mac := .catalyst
  uses := ["auth", "keychain.*", "http.get", "ble.*", "bgtask.*"]
  -- the Probes tab calls cloudkit.* without an iCloud container on purpose, to show the shell's
  -- missingEntitlement answer (listing it in uses would rightly ask for iCloudContainers)
  unlisted := ["cloudkit.*"]
  usage := [
    ("NSFaceIDUsageDescription", "Shows that a Lean app can ask for Face ID."),
    -- asked only when NATIVEDEMO_BLE_SERVICE is set at launch (the Probes tab's Bluetooth section)
    ("NSBluetoothAlwaysUsageDescription", "Shows that a Lean app can connect to a Bluetooth LE peripheral.")]
  -- the Probes tab schedules them
  backgroundTasks := [("art.fralex.elmlean.nativedemo.refresh", .refresh),
                      ("art.fralex.elmlean.nativedemo.processing", .processing)]
  uiTests := some {}

def main := manifest.main
