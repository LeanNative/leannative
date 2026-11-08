import LeanNative.Native

/-! # A scripted heart-rate sensor, for test mode

A simulator has no Bluetooth radio and no enrolled face, so in test mode (a Debug build launched with
`BTAUTH_E2E=1`) the app's capability calls for `auth` and `ble.*` are answered here instead of by the shell, with
the shell's own answers (`LeanNativeShell/Capabilities.lean`): authentication succeeds, and Bluetooth is on with
one peripheral, `LeanNative HR`, offering the Heart Rate service. Every other capability (the keychain) still
goes to the shell. The typed clients cannot tell the difference, which is the point: the app's code from the
button to the reading is the code that talks to a real sensor. `BTAUTH_E2E_SENSOR` at launch makes it a sensor
that fails (`Script`): `absent` is out of range, so the connection times out; `drops` goes out of range after
three readings.

The sensor follows the Bluetooth SIG's Heart Rate service: Heart Rate Measurement (`2A37`, notify) sends a
flags byte (bit 0 clear: the rate is one byte) and the rate; Heart Rate Control Point (`2A39`, write) takes
`01`, reset energy expended. -/

namespace BluetoothAuth.Fake
open Lean LeanNative.Native

def heartRateService : String := "180D"
def measurement : String := "2A37"
def controlPoint : String := "2A39"
def peripheralId : String := "fake-heart-rate-sensor"
def peripheralName : String := "LeanNative HR"

/-- The rates it sends, over and over. -/
def rates : Array Nat := #[72, 74, 77, 79, 76, 73, 71, 70]

/-- What the sensor does (`BTAUTH_E2E_SENSOR`). -/
inductive Script where
  /-- in range, sending until it is closed (unset) -/
  | inRange
  /-- out of range: a connection times out, as the shell's does when a scan finds nothing (`absent`) -/
  | absent
  /-- out of range after `readings` readings: the next read, and anything after it, answers `disconnected`
  (`drops`: after three) -/
  | drops (readings : Nat)
  deriving BEq, Repr

def Script.ofName? : String → Option Script
  | "absent" => some .absent
  | "drops" => some (.drops 3)
  | _ => none

structure Sensor where
  script : Script
  connected : IO.Ref Bool
  subscribed : IO.Ref Bool
  /-- the next of `rates` -/
  next : IO.Ref Nat
  resets : IO.Ref Nat

def Sensor.new (script : Script := .inRange) : IO Sensor :=
  return { script, connected := ← IO.mkRef false, subscribed := ← IO.mkRef false, next := ← IO.mkRef 0, resets := ← IO.mkRef 0 }

/-- Whether test mode answers this capability (everything else goes to the shell). -/
def answers (name : String) : Bool := name == "auth" || name.startsWith "ble."

private def str (args : Json) (k : String) : String := (args.getObjValAs? String k).toOption.getD ""
private def okJ : Json := Json.mkObj [("ok", true)]
private def failJ (error : String) : Json := Json.mkObj [("ok", false), ("error", Json.str error)]

private def hex (bytes : List Nat) : String :=
  let digit (n : Nat) : Char := "0123456789abcdef".toList[n]!
  String.ofList (bytes.flatMap fun b => [digit (b / 16 % 16), digit (b % 16)])

/-- The shell's answer to `name` with `args`, as the sensor and an enrolled face would give it. A read waits
the sensor's interval (a reading every 0.4 s). -/
def Sensor.answer (s : Sensor) (name : String) (args : Json) : IO Json := do
  match name with
  | "auth" => return okJ
  | "ble.state" => return Json.mkObj [("state", "poweredOn")]
  | "ble.connect" =>
    let services := match args.getObjVal? "services" with
      | .ok (.arr a) => a.toList.filterMap fun (j : Json) => j.getStr?.toOption
      | _ => []
    unless services.any (fun (u : String) => u.toUpper == heartRateService) do return failJ "timeout"
    if s.script == .absent then return failJ "timeout"
    s.connected.set true
    return Json.mkObj [("ok", true), ("id", Json.str peripheralId), ("name", Json.str peripheralName),
      ("service", Json.str heartRateService), ("characteristics", Json.arr #[Json.str measurement, Json.str controlPoint])]
  | "ble.subscribe" =>
    unless ← s.connected.get do return failJ "disconnected"
    unless (str args "characteristic").toUpper == measurement do return failJ "no-characteristic"
    s.subscribed.set true
    return okJ
  | "ble.read" =>
    IO.sleep 400
    unless (← s.connected.get) && (← s.subscribed.get) do return Json.mkObj [("error", "disconnected")]
    if let .drops n := s.script then
      if (← s.next.get) ≥ n then
        s.connected.set false
        s.subscribed.set false
        return Json.mkObj [("error", "disconnected")]
    let i ← s.next.modifyGet fun i => (i, i + 1)
    return Json.mkObj [("hex", Json.str (hex [0, rates[i % rates.size]!]))]
  | "ble.write" =>
    unless ← s.connected.get do return failJ "disconnected"
    unless (str args "characteristic").toUpper == controlPoint && str args "hex" == "01" do return failJ "refused"
    s.resets.modify (· + 1)
    return okJ
  | "ble.close" =>
    s.connected.set false
    s.subscribed.set false
    return okJ
  | _ => return failJ "unsupported"

/-- `fx` with `auth` and `ble.*` answered by the sensor; everything else as before. -/
def Sensor.wrap (s : Sensor) (fx : Effects Host) : Effects Host :=
  { post := fx.post
    cap := fun name args k =>
      if answers name then discard <| IO.asTask (prio := .dedicated) do fx.post (k (← s.answer name args))
      else fx.cap name args k
    ask := fun name args =>
      if answers name then do
        let t ← IO.asTask (prio := .dedicated) (s.answer name args)
        return t.map fun r => match r with
          | .ok j => j
          | .error e => Json.mkObj [("ok", false), ("error", Json.str (toString e))]
      else fx.ask name args }

end BluetoothAuth.Fake
