import LeanNative.Native.Client

/-! # Keychain items (`keychain.get/set/add/delete/clear/protect/attributes`)

A generic password item is named by its `key` (the account) and `service` (the bundle id when absent);
`synchronizable` items are iCloud Keychain's (`kSecAttrSynchronizable`) and readable while unlocked,
the others this device's only, while unlocked (`WhenUnlockedThisDeviceOnly`).

| request | answer | result |
|---|---|---|
| `get item` | `{"hex":…\|null,"status":n}` | the bytes, or `none` for `errSecItemNotFound` |
| `getText item` | `{"value":…\|null,"status":n}` | the UTF-8 text, or `none`; an item that is not UTF-8 is `failed notText` |
| `set item bytes` | `{"ok","status"}` | replaces the value of any item of that name, in place (an update; an add when there is none): a write that fails leaves the old value |
| `add item bytes` | `{"ok","status","exists"}` | `.added`, or `.alreadyExists` and the item is untouched |
| `delete item` | `{"ok","status"}` | also succeeds when there was no item |
| `clear service` | `{"ok","status"}` | every item of the service (a test namespace's reset) |
| `protect item` | `{"ok","status","changed"}` | puts an item that is there behind the person's presence, in place; whether it changed anything |
| `attributes item` | `{"status","accessible","userPresence","synchronizable"}` | what protects the item, never its value; `none` when there is no item |

`add` is the create-only operation: one `SecItemAdd`, which the Keychain refuses with
`errSecDuplicateItem` when the item exists, so two racing `add`s cannot both succeed on this device.
It is **not** built from `get` then `set`, which would race. For a `synchronizable` item it does not
reach other devices: an item another device adds is merged by iCloud Keychain later, as iCloud decides.
`status` on `get` and the `keychain.add` capability are compatible extensions of the shell's protocol.

A failed `OSStatus` is an `Error` named `status <n>` with `code := n`: `errSecMissingEntitlement`
(-34018: an ad-hoc signed Mac Catalyst build has no keychain access group) is `unsupported`,
`errSecUserCanceled` (-128) `cancelled`, `errSecAuthFailed` (-25293) `denied`, anything else `failed`
(`errSecInteractionNotAllowed`, -25308, while the device is locked, and for a read the person has not
authenticated: see below).

## An item behind the person's presence (`access := .userPresence`)

By default (`.unlocked`) an item is readable by any code in the app while the device is unlocked.
`access := .userPresence` asks `add` for an access control instead of a protection class
(`kSecAccessControlUserPresence` over `WhenUnlockedThisDeviceOnly`): the Keychain itself then gives the
value only after Face ID, Touch ID or the passcode. `"access":"userPresence"` is sent only when set, so a
request about an `.unlocked` item is what it always was.

**The Keychain capability never asks the person and never keeps the main thread waiting for them.** The app
asks, once, with `Auth.authenticate reason (keep := some seconds)`, and names the context that answers
in the reads that follow: `get item (context := some id)`. Any number of reads may use it while it
lives (`Client.Auth` has its lifetime). A read of such an item with no context, or with one that has
ended or never was, is a `failed` `status -25308` (`errSecInteractionNotAllowed`), not a prompt.

* `add` with `.userPresence` creates the item behind the access control, or answers `.alreadyExists` and
  leaves the item as it is, whatever protects it. With `synchronizable` it is refused (`status -50`):
  an access control is one device's.
* `set` with `.userPresence` is refused (`status -50`), and `set` over an item that is behind an access
  control is a `status -25308`, the item as it was: `set` neither creates nor rewrites such an item (the
  shell looks for it before it writes, and the Keychain refuses the write besides). Replace its value
  with `delete` then `add`.
* `protect item` upgrades an item that is there, in place: one `SecItemUpdate` that gives it the access
  control. It never deletes, never adds again and never reads the value, and a failure leaves the item as
  it was. `true` when it changed the item, `false` when the item was already protected. Refused for a
  `synchronizable` item (`status -50`); an item that is not there is `status -25300`.
* `attributes item` reads what protects an item (`kSecReturnAttributes`, never the value): its
  protection class, whether it is behind the person's presence, whether it syncs. It needs no
  authentication. An access control cannot be read back, and a device's Keychain gives nothing of an item
  behind one without the person, its attributes included: on an unlocked device the shell reads that
  refusal as the answer (`userPresence := true`, `accessible := none`), and `protect` and `set` read it
  the same way. On a locked device the refusal says only that, and is a `failed` `status -25308`. A
  simulator's Keychain gives the attributes, and there the item is known by a marker the shell writes with
  the access control (`kSecAttrGeneric`).

A device without a passcode cannot hold an access control: `add` and `protect` fail with the Keychain's
status (`-25293`, `denied`) and nothing is stored unprotected. A simulator is not a device here. One
whose Keychain refuses the access control for want of a passcode has `add` store the item in the plain
class and `protect` leave it as it is, there only, both answering `"access":"unlocked"` (`addApplied` and
`attributes` show it). And a simulator's Keychain may take the access control and then give the value
without any authentication (the iOS 27.2 simulator does): everything answers as on a device but the read
with no context, which is not refused. That the Keychain refuses it is a device's to show; the headless
driver's fake shell (`Journey.Wire`) refuses it as a device does. -/

namespace LeanNative.Native.Client.Keychain
open Lean LeanNative.Native.Client

/-- What a read of an item's value asks for. -/
inductive Access where
  /-- Readable while the device is unlocked: the protection class alone. -/
  | unlocked
  /-- Readable only with the person present (Face ID, Touch ID or the passcode), which the Keychain itself
  checks: an access control, this device only. -/
  | userPresence
  deriving Repr, BEq, Inhabited, DecidableEq

/-- The name on the wire (`"access"`). -/
def Access.name : Access → String
  | .unlocked => "unlocked"
  | .userPresence => "userPresence"

structure Item where
  key : String
  /-- The service; the app's bundle id when absent. -/
  service : Option String := none
  synchronizable : Bool := false
  /-- What a read of the value asks for; sent only when it is not `.unlocked`. -/
  access : Access := .unlocked
  deriving Repr, BEq, Inhabited

def Item.args (i : Item) (extra : List (String × Option Json) := []) : Json :=
  obj ([("key", some (Json.str i.key)), ("service", i.service.map Json.str),
        ("synchronizable", if i.synchronizable then some (Json.bool true) else none),
        ("access", if i.access == .userPresence then some (Json.str i.access.name) else none)] ++ extra)

def errSecItemNotFound : Int := -25300
def errSecDuplicateItem : Int := -25299
/-- A read the Keychain would have to ask the person for, which the shell never lets it: the item is behind
an access control and the request named no live authentication context (or the device is locked). -/
def errSecInteractionNotAllowed : Int := -25308

def statusError (status : Int) : Error :=
  let kind : Kind :=
    if status == -34018 then .unsupported
    else if status == -128 then .cancelled
    else if status == -25293 then .denied
    else .failed
  { kind, name := s!"status {status}", code := some status }

/-- `{"ok","status"}` with `ok` agreeing with `status == 0`. -/
def decodeOk (j : Json) : Result Unit := do
  let ok ← reqBool j "ok"
  let status ← reqInt j "status"
  if ok != (status == 0) && !(ok && status == errSecItemNotFound) then
    throw (malformed s!"ok {ok} with status {status}")
  unless ok do throw (statusError status)

def decodeGet (field : String) (j : Json) : Result (Option String) := do
  let status ← reqInt j "status"
  if status == errSecItemNotFound then
    if (← optString j field).isSome then throw (malformed s!"`{field}` with errSecItemNotFound")
    return none
  unless status == 0 do throw (statusError status)
  match ← optString j field with
  | some s => pure (some s)
  | none => if field == "value" then throw (failed "notText" "the item is not UTF-8 text") else throw (malformed s!"no `{field}` with status 0")

/-- `context` is a kept authentication's id (`Auth.authenticate reason (keep := …)`), for an item behind the
person's presence; sent only when given. -/
def get (item : Item) (context : Option String := none) : Request (Option ByteArray) :=
  { capability := "keychain.get", args := item.args [("hex", some (Json.bool true)), ("context", context.map Json.str)]
    decode := fun j => do
      match ← decodeGet "hex" j with
      | none => pure none
      | some h => match bytesOfHex? h with
        | some b => pure (some b)
        | none => throw (malformed "`hex` is not hex") }

def getText (item : Item) (context : Option String := none) : Request (Option String) :=
  { capability := "keychain.get", args := item.args [("context", context.map Json.str)], decode := decodeGet "value" }

def set (item : Item) (bytes : ByteArray) : Request Unit :=
  { capability := "keychain.set", args := item.args [("hex", some (Json.str (hexOf bytes)))], decode := decodeOk }

def setText (item : Item) (text : String) : Request Unit :=
  { capability := "keychain.set", args := item.args [("value", some (Json.str text))], decode := decodeOk }

inductive Added where
  | added
  | alreadyExists
  deriving Repr, BEq, Inhabited

def decodeAdded (j : Json) : Result Added := do
  let ok ← reqBool j "ok"
  let status ← reqInt j "status"
  if ok && status == 0 then return .added
  if !ok && status == errSecDuplicateItem then return .alreadyExists
  if ok then throw (malformed s!"ok with status {status}")
  throw (statusError status)

/-- The answer's `access`: what the shell gave the item. Absent is `.unlocked`: a shell that says nothing
applied no access control. -/
def decodeAccess (j : Json) : Result Access := do
  match ← optString j "access" with
  | none | some "unlocked" => pure .unlocked
  | some "userPresence" => pure .userPresence
  | some other => throw (malformed s!"`access` is {other}")

def add (item : Item) (bytes : ByteArray) : Request Added :=
  { capability := "keychain.add", args := item.args [("hex", some (Json.str (hexOf bytes)))], decode := decodeAdded }

/-- `add`, with the access the shell gave an item it added: `.unlocked` for a `.userPresence` item only on a
simulator whose Keychain refuses an access control for want of a passcode (a device fails the `add` instead).
For `.alreadyExists` it is the access asked for, and says nothing of the item that is there: `attributes`
reads that. -/
def addApplied (item : Item) (bytes : ByteArray) : Request (Added × Access) :=
  { capability := "keychain.add", args := item.args [("hex", some (Json.str (hexOf bytes)))]
    decode := fun j => do
      match ← decodeAdded j with
      | .added => return (.added, ← decodeAccess j)
      | .alreadyExists => return (.alreadyExists, item.access) }

def delete (item : Item) : Request Unit :=
  { capability := "keychain.delete", args := item.args, decode := decodeOk }

def clear (service : String) (synchronizable : Bool := false) : Request Unit :=
  { capability := "keychain.clear"
    args := obj [("service", some (Json.str service)), ("synchronizable", if synchronizable then some (Json.bool true) else none)]
    decode := decodeOk }

/-- Puts an item that is there behind the person's presence, in place (the module documentation has what it
never does). Whether it changed the item: `false` when it was already protected, and on a simulator whose
Keychain refuses an access control, where it cannot be (`attributes` then still says `userPresence := false`). -/
def protect (item : Item) : Request Bool :=
  { capability := "keychain.protect", args := { item with access := .userPresence }.args
    decode := fun j => do
      let ok ← reqBool j "ok"
      let status ← reqInt j "status"
      if ok != (status == 0) then throw (malformed s!"ok {ok} with status {status}")
      unless ok do throw (statusError status)
      reqBool j "changed" }

/-- What protects an item. -/
structure Attributes where
  /-- The protection class: `whenUnlocked`, `whenUnlockedThisDeviceOnly`, `afterFirstUnlock`,
  `afterFirstUnlockThisDeviceOnly`, `whenPasscodeSetThisDeviceOnly`, another as the system names it, or
  `none` when the system does not say, as it does not of an item behind an access control on a device. -/
  accessible : Option String := none
  /-- Behind the person's presence: `add` with `.userPresence` or `protect` made it so. -/
  userPresence : Bool := false
  synchronizable : Bool := false
  deriving Repr, BEq, Inhabited

def Attributes.access (a : Attributes) : Access := if a.userPresence then .userPresence else .unlocked

/-- What protects an item, or `none` when there is no item. Never its value, so it needs no authentication. -/
def attributes (item : Item) : Request (Option Attributes) :=
  { capability := "keychain.attributes", args := item.args
    decode := fun j => do
      let status ← reqInt j "status"
      if status == errSecItemNotFound then return none
      unless status == 0 do throw (statusError status)
      return some { accessible := ← optString j "accessible", userPresence := ← reqBool j "userPresence",
                    synchronizable := ← reqBool j "synchronizable" } }

end LeanNative.Native.Client.Keychain
