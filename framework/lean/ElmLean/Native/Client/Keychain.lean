import ElmLean.Native.Client

/-! # Keychain items (`keychain.get/set/add/delete/clear`)

A generic password item is named by its `key` (the account) and `service` (the bundle id when absent);
`synchronizable` items are iCloud Keychain's (`kSecAttrSynchronizable`) and readable while unlocked,
the others this device's only, while unlocked (`WhenUnlockedThisDeviceOnly`).

| request | answer | result |
|---|---|---|
| `get item` | `{"hex":…\|null,"status":n}` | the bytes, or `none` for `errSecItemNotFound` |
| `getText item` | `{"value":…\|null,"status":n}` | the UTF-8 text, or `none`; an item that is not UTF-8 is `failed notText` |
| `set item bytes` | `{"ok","status"}` | replaces any item of that name (delete, then add: not atomic) |
| `add item bytes` | `{"ok","status","exists"}` | `.added`, or `.alreadyExists` and the item is untouched |
| `delete item` | `{"ok","status"}` | also succeeds when there was no item |
| `clear service` | `{"ok","status"}` | every item of the service (a test namespace's reset) |

`add` is the create-only operation: one `SecItemAdd`, which the Keychain refuses with
`errSecDuplicateItem` when the item exists, so two racing `add`s cannot both succeed on this device.
It is **not** built from `get` then `set`, which would race. For a `synchronizable` item it does not
reach other devices: an item another device adds is merged by iCloud Keychain later, as iCloud decides.
`status` on `get` and the `keychain.add` capability are compatible extensions of the shell's protocol.

A failed `OSStatus` is an `Error` named `status <n>` with `code := n`: `errSecMissingEntitlement`
(-34018: an ad-hoc signed Mac Catalyst build has no keychain access group) is `unsupported`,
`errSecUserCanceled` (-128) `cancelled`, `errSecAuthFailed` (-25293) `denied`, anything else `failed`
(`errSecInteractionNotAllowed`, -25308, while the device is locked). -/

namespace ElmLean.Native.Client.Keychain
open Lean ElmLean.Native.Client

structure Item where
  key : String
  /-- The service; the app's bundle id when absent. -/
  service : Option String := none
  synchronizable : Bool := false
  deriving Repr, BEq, Inhabited

def Item.args (i : Item) (extra : List (String × Option Json) := []) : Json :=
  obj ([("key", some (Json.str i.key)), ("service", i.service.map Json.str),
        ("synchronizable", if i.synchronizable then some (Json.bool true) else none)] ++ extra)

def errSecItemNotFound : Int := -25300
def errSecDuplicateItem : Int := -25299

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

def get (item : Item) : Request (Option ByteArray) :=
  { capability := "keychain.get", args := item.args [("hex", some (Json.bool true))]
    decode := fun j => do
      match ← decodeGet "hex" j with
      | none => pure none
      | some h => match bytesOfHex? h with
        | some b => pure (some b)
        | none => throw (malformed "`hex` is not hex") }

def getText (item : Item) : Request (Option String) :=
  { capability := "keychain.get", args := item.args, decode := decodeGet "value" }

def set (item : Item) (bytes : ByteArray) : Request Unit :=
  { capability := "keychain.set", args := item.args [("hex", some (Json.str (hexOf bytes)))], decode := decodeOk }

def setText (item : Item) (text : String) : Request Unit :=
  { capability := "keychain.set", args := item.args [("value", some (Json.str text))], decode := decodeOk }

inductive Added where
  | added
  | alreadyExists
  deriving Repr, BEq, Inhabited

def add (item : Item) (bytes : ByteArray) : Request Added :=
  { capability := "keychain.add", args := item.args [("hex", some (Json.str (hexOf bytes)))]
    decode := fun j => do
      let ok ← reqBool j "ok"
      let status ← reqInt j "status"
      if ok && status == 0 then return .added
      if !ok && status == errSecDuplicateItem then return .alreadyExists
      if ok then throw (malformed s!"ok with status {status}")
      throw (statusError status) }

def delete (item : Item) : Request Unit :=
  { capability := "keychain.delete", args := item.args, decode := decodeOk }

def clear (service : String) (synchronizable : Bool := false) : Request Unit :=
  { capability := "keychain.clear"
    args := obj [("service", some (Json.str service)), ("synchronizable", if synchronizable then some (Json.bool true) else none)]
    decode := decodeOk }

end ElmLean.Native.Client.Keychain
