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

/-- Waits for the status line to say `expected`; a failure says what it said instead. -/
def statusIs (expected : String) (within : Float := 10) : UI Unit := do
  try waitUntil within s!"the status \"{expected}\"" do return (← text "status") == expected
  catch e => failure s!"{e}; it says \"{← text "status"}\""

/-- Unlocked, in test mode, with this sensor (`Fake.Script`'s name; none: the one in range). -/
def unlocked (sensor : Option String := none) : UI Unit := do
  launch (testMode ++ sensor.toList.map ("BTAUTH_E2E_SENSOR", ·))
  waitFor "testMode" 20
  tap "unlock"
  waitFor "connect" 20

/-- What the screen says when the sensor fails: a connection that times out, and a sensor that goes out of range
after three readings, each leaving no sensor shown and Connect offered again; then one disconnected by locking the
app while it reads, where the locked screen says it is locked. -/
def failures : Journey := ⟨"failures", do
  let disconnected : UI Unit := do
    expectEq "the sensor" (← text "sensor") "Not connected"
    expectEq "the rate" (← text "bpm") "—"
    expect (← state "connect").enabled "Connect is not offered again"
  unlocked "absent"
  tap "connect"
  statusIs "not connected: failed (timeout)"
  disconnected
  unlocked "drops"
  tap "connect"
  statusIs "readings stopped: disconnected" 20
  disconnected
  expectEq "the readings it sent" (← text "readings") "3 readings"
  -- locking disconnects the sensor, whose readings then stop: the locked screen still says it is locked
  unlocked
  tap "connect"
  waitUntil 20 "a reading" do return (← readings) ≥ 1
  tap "lock"
  waitFor "unlock" 10
  pause 2
  statusIs "locked" 0⟩

end BluetoothAuth.Journeys

open BluetoothAuth.Journeys in
def main (args : List String) : IO UInt32 :=
  LeanNative.Journey.main [monitor, failures] args (wire := some (LeanNative.Journey.Wire.app BluetoothAuth.app))
