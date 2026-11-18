import LeanNative.Native.Client

/-! # Device-owner authentication (`auth`, `auth.end`)

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

## A kept authentication (`keep`)

`authenticate reason (keep := some seconds)` asks the same question, and on a yes the shell keeps the
authentication for the reads that follow: `{"ok":true,"context":"<id>"}`. The id names it in
`Keychain.get item (context := some id)`, so an action that reads several items behind the person's
presence asks the person once. Without `keep` the request and its answer are exactly as they were.

A kept authentication ends at the first of: `Auth.end id`; its time, `keep` seconds after the answer (the
shell allows at most 60); and the app going to the background. Not when the app merely becomes inactive,
which the Face ID sheet itself causes. Any number of reads may use it until then; after, its id is an
unknown one, and a read that names it is refused as a read with no context is. End it as soon as the
action is over rather than leaving it to its time.

The id is unguessable and means nothing outside this run of the app. An answer with no `context` to a
request with `keep` (the app was already in the background when the person answered, or `keep` was 0) is a
success with nothing kept. On the simulator without a passcode the context is kept all the same, having
checked nothing: it satisfies no access control, and there is none there to satisfy.

A manifest's `uses` lists `auth.end` beside `auth` (or `auth.*` for both).

Availability: iOS and Mac Catalyst (Touch ID or the login password). Face ID needs
`NSFaceIDUsageDescription` in Info.plist. Authentication proves to the app only that the shell said
so; what the app then protects is its own decision. -/

namespace LeanNative.Native.Client.Auth
open Lean LeanNative.Native.Client

structure Success where
  /-- The shell's note (the simulator without a passcode says so). -/
  note : Option String := none
  /-- The kept authentication's id, when `keep` asked for one and the shell kept it. -/
  context : Option String := none
  deriving Repr, BEq, Inhabited

def kindOf (name : String) : Kind :=
  if ["userCancel", "appCancel", "systemCancel", "userFallback"].contains name then .cancelled
  else if ["authenticationFailed", "biometryLockout"].contains name then .denied
  else if ["passcodeNotSet", "biometryNotAvailable", "biometryNotEnrolled", "notInteractive"].contains name then .unsupported
  else .failed

def decode (j : Json) : Result Success := do
  if ← reqBool j "ok" then
    return { note := ← optString j "note", context := ← optString j "context" }
  let name := (← optString j "name").getD "unknown"
  throw { kind := kindOf name, name, code := ← optInt j "code", domain := ← optString j "domain", detail := (← optString j "error").getD "" }

/-- With `keep` (seconds; the shell allows at most 60), a yes keeps the authentication for the Keychain reads
that name its `context`; sent only when given. -/
def authenticate (reason : String) (keep : Option Nat := none) : Request Success :=
  { capability := "auth", args := obj [("reason", some (Json.str reason)), ("keep", keep.map fun n => toJson n)], decode }

/-- Ends a kept authentication (`Auth.end id`): its id is unknown from here on. Ending one that has ended,
or never was, is not an error. -/
def «end» (context : String) : Request Unit :=
  { capability := "auth.end", args := Json.mkObj [("context", Json.str context)]
    decode := fun j => do
      unless ← reqBool j "ok" do throw (failed ((← optString j "error").getD "notEnded")) }

end LeanNative.Native.Client.Auth
