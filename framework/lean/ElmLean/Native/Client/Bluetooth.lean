import ElmLean.Native.Client

/-! # Bluetooth LE GATT (`ble.state/connect/subscribe/write/read/close`)

Generic: a peripheral by the services it offers, characteristics by UUID, values as bytes. The
services, characteristics, framing and timeouts of a particular device are the app's.

Errors are `{"ok":false,"error":name}` (or `{"error":name}` for `read`):

| `error` | kind |
|---|---|
| `unauthorized` (the person has not allowed Bluetooth) | `denied` |
| `unsupported` (no Bluetooth LE) | `unsupported` |
| `poweredOff`, `resetting`, `unknown`, `timeout`, `refused`, `busy`, `disconnected`, `no-service`, `no-services`, `no-characteristic`, `no-characteristics`, `bad-hex`, … | `failed` |

Availability: iOS and Mac Catalyst; the app declares `NSBluetoothAlwaysUsageDescription`. iOS pairs on
the first encrypted access, so `subscribe` can wait on the person. -/

namespace ElmLean.Native.Client.Bluetooth
open Lean ElmLean.Native.Client

inductive State where
  | poweredOn | poweredOff | unauthorized | unsupported | resetting | unknown
  deriving Repr, BEq, Inhabited

def State.ofName? : String → Option State
  | "poweredOn" => some .poweredOn
  | "poweredOff" => some .poweredOff
  | "unauthorized" => some .unauthorized
  | "unsupported" => some .unsupported
  | "resetting" => some .resetting
  | "unknown" => some .unknown
  | _ => none

def errorKind (name : String) : Kind :=
  if name == "unauthorized" then .denied else if name == "unsupported" then .unsupported else .failed

def bleError (name : String) : Error := { kind := errorKind name, name }

/-- `{"ok":true,…}`, or `{"ok":false,"error":name}`. -/
def decodeOk (j : Json) : Result Unit := do
  unless ← reqBool j "ok" do
    match ← optString j "error" with
    | some name => throw (bleError name)
    | none => throw (malformed "`ok` false without `error`")

def state : Request State :=
  { capability := "ble.state", args := Json.mkObj []
    decode := fun j => do
      let s ← reqString j "state"
      match State.ofName? s with
      | some st => pure st
      | none => throw (malformed s!"state {s}") }

structure Connection where
  /-- The peripheral, for the other requests. -/
  id : String
  /-- Its advertised name, when it has one (a shell that does not report it gives none). -/
  name : Option String := none
  /-- The service it offered (one of those asked for). -/
  service : String
  characteristics : Array String
  deriving Repr, BEq, Inhabited

/-- Connects to the first peripheral offering one of `services` (one the system already holds connected,
else the first a scan finds), within `timeout` s (the shell's default, 45). -/
def connect (services : List String) (timeout : Option Nat := none) : Request Connection :=
  { capability := "ble.connect"
    args := obj [("services", some (Json.arr (services.toArray.map Json.str))), ("timeout", timeout.map toJson)]
    decode := fun j => do
      decodeOk j
      let chars ← match j.getObjVal? "characteristics" with
        | .ok (.arr cs) => cs.mapM fun c => match c with
          | .str s => pure s
          | _ => throw (malformed "a characteristic is not a string")
        | _ => throw (malformed "no `characteristics`")
      return { id := ← reqString j "id", name := ← optString j "name", service := ← reqString j "service", characteristics := chars } }

/-- Notifications on: answered once they are on (pairing may happen here). -/
def subscribe (id characteristic : String) (timeout : Option Nat := none) : Request Unit :=
  { capability := "ble.subscribe"
    args := obj [("id", some (Json.str id)), ("characteristic", some (Json.str characteristic)), ("timeout", timeout.map toJson)]
    decode := decodeOk }

/-- One write; with `response` (the default), answered once the peripheral acknowledges. -/
def write (id characteristic : String) (bytes : ByteArray) (response : Bool := true) (timeout : Option Nat := none) :
    Request Unit :=
  { capability := "ble.write"
    args := obj [("id", some (Json.str id)), ("characteristic", some (Json.str characteristic)),
                 ("hex", some (Json.str (hexOf bytes))), ("response", some (Json.bool response)), ("timeout", timeout.map toJson)]
    decode := decodeOk }

/-- The next notified value of `characteristic`, in arrival order. -/
def read (id characteristic : String) (timeout : Option Nat := none) : Request ByteArray :=
  { capability := "ble.read"
    args := obj [("id", some (Json.str id)), ("characteristic", some (Json.str characteristic)), ("timeout", timeout.map toJson)]
    decode := fun j => do
      if let some name ← optString j "error" then throw (bleError name)
      reqHex j "hex" }

/-- Disconnects; requests waiting on the peripheral fail with `disconnected`. -/
def close (id : String) : Request Unit :=
  { capability := "ble.close", args := Json.mkObj [("id", Json.str id)], decode := decodeOk }

end ElmLean.Native.Client.Bluetooth
