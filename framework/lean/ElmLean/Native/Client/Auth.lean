import ElmLean.Native.Client

/-! # Device-owner authentication (`auth`)

`authenticate reason` asks for Face ID, Touch ID or the passcode (`LAPolicyDeviceOwnerAuthentication`).
The shell answers `{"ok":true}`, or `{"ok":false,"error":text,"name":…,"code":…}`: `name` and `code` are
the `LAError` (a compatible extension: `error` is the system's text, as before). The simulator without a
passcode answers `{"ok":true,"note":…}`.

| `name` | kind |
|---|---|
| `userCancel`, `appCancel`, `systemCancel`, `userFallback` | `cancelled` |
| `authenticationFailed`, `biometryLockout` | `denied` |
| `passcodeNotSet`, `biometryNotAvailable`, `biometryNotEnrolled`, `notInteractive` | `unsupported` |
| anything else (`invalidContext`, `unknown`, …) | `failed` |

Availability: iOS and Mac Catalyst (Touch ID or the login password). Face ID needs
`NSFaceIDUsageDescription` in Info.plist. Authentication proves to the app only that the shell said
so; what the app then protects is its own decision. -/

namespace ElmLean.Native.Client.Auth
open Lean ElmLean.Native.Client

structure Success where
  /-- The shell's note (the simulator without a passcode says so). -/
  note : Option String := none
  deriving Repr, BEq, Inhabited

def kindOf (name : String) : Kind :=
  if ["userCancel", "appCancel", "systemCancel", "userFallback"].contains name then .cancelled
  else if ["authenticationFailed", "biometryLockout"].contains name then .denied
  else if ["passcodeNotSet", "biometryNotAvailable", "biometryNotEnrolled", "notInteractive"].contains name then .unsupported
  else .failed

def decode (j : Json) : Result Success := do
  if ← reqBool j "ok" then
    return { note := ← optString j "note" }
  let name := (← optString j "name").getD "unknown"
  throw { kind := kindOf name, name, code := ← optInt j "code", detail := (← optString j "error").getD "" }

def authenticate (reason : String) : Request Success :=
  { capability := "auth", args := Json.mkObj [("reason", Json.str reason)], decode }

end ElmLean.Native.Client.Auth
