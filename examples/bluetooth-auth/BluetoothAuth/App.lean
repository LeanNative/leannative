import LeanNative.Native
import LeanNative.Native.Client.Auth
import LeanNative.Native.Client.Bluetooth
import LeanNative.Native.Client.Keychain
import BluetoothAuth.Fake

/-! # Bluetooth and authentication: a heart-rate monitor behind Face ID

* `auth` (Face ID, else the passcode) unlocks the app; locking it disconnects the sensor;
* `ble.*`: the Bluetooth state, then a connection to the first sensor offering the Heart Rate service (`180D`),
  its measurements (`2A37`) subscribed to and read one by one, and its control point (`2A39`) written to reset
  the energy expended;
* `keychain.*`: the last sensor's name, remembered across launches until forgotten.

Every capability is asked through the typed clients (`LeanNative.Native.Client.*`). In test mode (a Debug build,
which the shell's `build` says, launched with `BTAUTH_E2E=1`) `auth` and `ble.*` are answered by a scripted
sensor instead (`BluetoothAuth.Fake`), so the journey runs on a simulator and headless; a Release build never
enters it. -/

namespace BluetoothAuth
open LeanNative LeanNative.Native Lean

structure Model where
  unlocked : Bool := false
  testMode : Bool := false
  status : String := ""
  bleState : String := "not asked yet"
  /-- the connected sensor: its id (for the other requests) and name -/
  sensor : Option (String × String) := none
  connecting : Bool := false
  bpm : Option Nat := none
  readings : Nat := 0
  remembered : Option String := none
  deriving Inhabited

inductive Host where
  | testMode
  | authed (ok : Bool) (detail : String)
  | bleState (state : String)
  | remembered (name : Option String)
  | connected (id name : String)
  | notConnected (why : String)
  | beat (bpm : Nat)
  /-- the readings stopped: disconnected, or an error -/
  | ended (why : String)
  | reset (ok : Bool)
  | forgotten

inductive Msg where
  | unlock
  | lock
  | connect
  | disconnect
  | resetEnergy
  | forget
  | host (h : Host)

inductive Cmd where
  /-- at launch: test mode, when asked for and allowed -/
  | setup
  | authenticate
  | readState
  | recall
  | connect
  | close (id : String)
  | resetEnergy (id : String)
  | forget
  deriving ToJson

def update : Msg → Model → Model
  | .unlock, m => { m with status := "asking for Face ID or the passcode…" }
  | .lock, m => { m with unlocked := false, sensor := none, connecting := false, bpm := none, status := "locked" }
  | .connect, m => { m with connecting := true, status := "looking for a heart-rate sensor…" }
  | .disconnect, m => { m with status := "disconnecting…" }
  | .resetEnergy, m => { m with status := "resetting the energy expended…" }
  | .forget, m => m
  | .host .testMode, m => { m with testMode := true }
  | .host (.authed ok d), m => if ok then { m with unlocked := true, status := "unlocked" } else { m with status := s!"still locked: {d}" }
  | .host (.bleState s), m => { m with bleState := s }
  | .host (.remembered n), m => { m with remembered := n }
  | .host (.connected id name), m =>
    { m with sensor := some (id, name), connecting := false, remembered := some name, readings := 0, status := s!"connected to {name}" }
  | .host (.notConnected why), m => { m with connecting := false, status := s!"not connected: {why}" }
  | .host (.beat bpm), m => { m with bpm := some bpm, readings := m.readings + 1 }
  | .host (.ended why), m => { m with sensor := none, connecting := false, bpm := none, status := s!"readings stopped: {why}" }
  | .host (.reset ok), m => { m with status := if ok then "energy expended reset" else "the sensor refused the reset" }
  | .host .forgotten, m => { m with remembered := none, status := "forgotten" }

def cmds : Msg → Model → List Cmd
  | .unlock, _ => [.authenticate]
  | .host (.authed true _), _ => [.readState, .recall]
  | .connect, _ => [.connect]
  | .disconnect, m | .lock, m => (m.sensor.map fun (id, _) => Cmd.close id).toList
  | .resetEnergy, m => (m.sensor.map fun (id, _) => Cmd.resetEnergy id).toList
  | .forget, _ => [.forget]
  | _, _ => []

def testModeNote : Html Msg :=
  .identified "testMode" (.text "Test mode: a scripted sensor and authentication stand in for the hardware." .caption)

def locked (m : Model) : Html Msg :=
  .screen "Heart Rate" none
    [ .col ([ .text "Locked" .title
            , .text "Your heart rate is behind Face ID or the passcode." .body
            , .identified "unlock" (.button "Unlock" .primary (some .unlock))
            , .identified "status" (.text m.status .caption) ]
            ++ (if m.testMode then [testModeNote] else [])) ]

def monitor (m : Model) : Html Msg :=
  let connected := m.sensor.isSome
  .screen "Heart Rate" none
    [ .list
      ((if m.testMode then [.section "" "" [testModeNote]] else []) ++
      [ .section "Sensor" "The first sensor offering the Heart Rate service (180D)."
          [ .identified "bleState" (.text s!"Bluetooth: {m.bleState}" .body)
          , .identified "sensor" (.text (match m.sensor with | some (_, n) => s!"Connected: {n}" | none => "Not connected") .body)
          , .row [ .identified "connect" (.button "Connect" .primary (if connected || m.connecting then none else some .connect)), .spacer
                 , .identified "disconnect" (.button "Disconnect" .plain (if connected then some .disconnect else none)) ] ]
      , .section "Reading" "Heart Rate Measurement (2A37), one notification at a time."
          [ .identified "bpm" (.text (match m.bpm with | some b => s!"{b} bpm" | none => "—") .title)
          , .identified "readings" (.text s!"{m.readings} {if m.readings == 1 then "reading" else "readings"}" .caption)
          , .identified "resetEnergy" (.button "Reset energy expended" .plain (if connected then some .resetEnergy else none)) ]
      , .section "Remembered" "The last sensor's name, kept in the keychain."
          [ .identified "remembered" (.text (match m.remembered with | some n => s!"Last sensor: {n}" | none => "No sensor remembered") .body)
          , .identified "forget" (.button "Forget" .plain (if m.remembered.isSome then some .forget else none)) ]
      , .section "" ""
          [ .identified "status" (.text m.status .caption)
          , .identified "lock" (.button "Lock" .plain (some .lock)) ] ]) ]

def view (m : Model) : Html Msg := if m.unlocked then monitor m else locked m

/-- Set at launch in test mode: the sensor that answers `auth` and `ble.*`. -/
initialize testSensor : IO.Ref (Option Fake.Sensor) ← IO.mkRef none

/-- The effects a command runs with: the shell's, or in test mode the scripted sensor's for `auth` and `ble.*`. -/
def effects (fx : Effects Host) : IO (Effects Host) := do
  return match ← testSensor.get with
    | some s => s.wrap fx
    | none => fx

def lastSensor : Client.Keychain.Item := { key := "lastSensor", service := some "art.fralex.leannative.bluetoothauth" }

def why (e : Client.Error) : String := if e.detail.isEmpty then s!"{e.kind.name} ({e.name})" else s!"{e.name}: {e.detail}"

/-- A Heart Rate Measurement: flags, then the rate (one byte, or two little-endian when flag bit 0 is set). -/
def rate (b : ByteArray) : Option Nat :=
  if b.size < 2 then none
  else if b[0]! &&& 1 == 0 then some b[1]!.toNat
  else if b.size < 3 then none
  else some (b[1]!.toNat + 256 * b[2]!.toNat)

def perform (c : Cmd) (fx₀ : Effects Host) : IO Unit := do
  let fx ← effects fx₀
  match c with
  | .setup =>
    if (← IO.getEnv "BTAUTH_E2E") == some "1" then
      discard <| IO.asTask (prio := .dedicated) do
        -- test mode only in a Debug build: the shell's `build` capability says which this is
        let build ← IO.wait (← fx₀.ask "build" (Json.mkObj []))
        if (build.getObjValAs? Bool "debug").toOption == some true then
          testSensor.set (some (← Fake.Sensor.new))
          fx.post .testMode
  | .authenticate => discard <| IO.asTask (prio := .dedicated) do
      match ← (Client.Auth.authenticate "Unlock your heart-rate monitor").call fx with
      | .ok _ => fx.post (.authed true "")
      | .error e => fx.post (.authed false (why e))
  | .readState => discard <| IO.asTask (prio := .dedicated) do
      let s := match ← Client.Bluetooth.state.call fx with
        | .ok .poweredOn => "on" | .ok .poweredOff => "off" | .ok .unauthorized => "not allowed"
        | .ok .unsupported => "unavailable" | .ok .resetting => "resetting" | .ok .unknown => "unknown"
        | .error e => why e
      fx.post (.bleState s)
  | .recall => discard <| IO.asTask (prio := .dedicated) do
      match ← (Client.Keychain.getText lastSensor).call fx with
      | .ok n => fx.post (.remembered n)
      | .error _ => fx.post (.remembered none)
  | .connect => discard <| IO.asTask (prio := .dedicated) do
      match ← (Client.Bluetooth.connect [Fake.heartRateService] (some 30)).call fx with
      | .error e => fx.post (.notConnected (why e))
      | .ok conn =>
        let name := conn.name.getD conn.id
        discard <| (Client.Keychain.setText lastSensor name).call fx
        fx.post (.connected conn.id name)
        match ← (Client.Bluetooth.subscribe conn.id Fake.measurement (some 30)).call fx with
        | .error e => fx.post (.ended (why e))
        | .ok () =>
          -- one reading at a time until the sensor goes away (closing it ends the reads with `disconnected`)
          let mut going := true
          while going do
            match ← (Client.Bluetooth.read conn.id Fake.measurement (some 15)).call fx with
            | .ok bytes => if let some r := rate bytes then fx.post (.beat r)
            | .error e => fx.post (.ended (if e.name == "disconnected" then "disconnected" else why e)); going := false
  | .close id => discard <| IO.asTask (prio := .dedicated) do
      discard <| (Client.Bluetooth.close id).call fx
  | .resetEnergy id => discard <| IO.asTask (prio := .dedicated) do
      let r ← (Client.Bluetooth.write id Fake.controlPoint (ByteArray.mk #[1])).call fx
      fx.post (.reset (r matches .ok _))
  | .forget => discard <| IO.asTask (prio := .dedicated) do
      discard <| (Client.Keychain.delete lastSensor).call fx
      fx.post .forgotten

def app : Native.App Model Msg Cmd Host :=
  { init := {}, update, view, cmds, host := Msg.host, perform, boot := [.setup] }

initialize Native.register app

end BluetoothAuth
