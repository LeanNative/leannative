import LeanNative.Journey
import LeanNative.Journey.Wire
import BluetoothAuth.App

/-! # The Bluetooth and authentication example's journey, from Lean on the host

In test mode (`BTAUTH_E2E=1`): the scripted sensor of `BluetoothAuth.Fake` answers `auth` and `ble.*`, and the
keychain is the simulator's (or, headless, the driver's).

    APP_DIR=examples/bluetooth-auth APP_ROOT=BluetoothAuth SCHEME=BluetoothAuth \
      UI_JOURNEY="$PWD/examples/bluetooth-auth/.lake/build/bin/journeys" framework/native/ci/ui-tests

or, with no simulator, against the app itself (LeanNative.Journey.Wire):

    LEANNATIVE_DRIVER=wire examples/bluetooth-auth/.lake/build/bin/journeys <evidence directory>

The screenshots are the website's (CI publishes them). -/

namespace BluetoothAuth.Journeys
open LeanNative LeanNative.Journey

def testMode : List (String × String) := [("BTAUTH_E2E", "1")]

/-- The number of readings shown. -/
def readings : UI Nat := do return (((← text "readings").splitOn " ").head!.toNat?).getD 0

/-- Unlock, connect, read the sensor, reset it, lock; then a new launch remembers the sensor until forgotten. -/
def monitor : Journey := ⟨"monitor", do
  launch testMode
  waitFor "testMode" 20
  shot "bluetooth-auth-locked"
  tap "unlock"
  waitFor "connect" 20
  waitUntil 10 "Bluetooth is on" do return (← text "bleState") == "Bluetooth: on"
  tap "connect"
  waitUntil 20 "connected" do return (← text "sensor") == s!"Connected: {Fake.peripheralName}"
  waitUntil 20 "three readings" do return (← readings) ≥ 3
  let bpm ← text "bpm"
  expect (Fake.rates.toList.any (s!"{·} bpm" == bpm)) s!"a rate the sensor sends: {bpm}"
  expectEq "the remembered sensor" (← text "remembered") s!"Last sensor: {Fake.peripheralName}"
  shot "bluetooth-auth-reading"
  tap "resetEnergy"
  waitUntil 10 "the reset" do return (← text "status") == "energy expended reset"
  tap "disconnect"
  waitUntil 10 "disconnected" do return (← text "sensor") == "Not connected"
  tap "lock"
  waitFor "unlock" 10
  -- a new launch: locked again, and the keychain still has the sensor
  launch testMode
  waitFor "testMode" 20
  tap "unlock"
  waitUntil 10 "the sensor remembered" do return (← text "remembered") == s!"Last sensor: {Fake.peripheralName}"
  shot "bluetooth-auth-remembered"
  tap "forget"
  waitUntil 10 "forgotten" do return (← text "remembered") == "No sensor remembered"⟩

end BluetoothAuth.Journeys

open BluetoothAuth.Journeys in
def main (args : List String) : IO UInt32 :=
  LeanNative.Journey.main [monitor] args (wire := some (LeanNative.Journey.Wire.app BluetoothAuth.app))
