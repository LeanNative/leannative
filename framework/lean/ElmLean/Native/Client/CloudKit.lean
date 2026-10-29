import ElmLean.Native.Client

/-! # CloudKit records (`cloudkit.account/query/save/load/delete`)

Records in the private database of a container (the app's default one, or `container`), default zone.
What the records mean, their types and fields, is the app's.

Every `cloudkit.*` error is `{"error":name,"code"?,"detail"?,"retryAfter"?}` with the `CKErrorCode` name
(`ElmShell/CloudKit.lean`):

| `error` | kind |
|---|---|
| `missingEntitlement` (no iCloud entitlement or container: an ad-hoc build) | `unsupported` |
| `notAuthenticated`, `permissionFailure`, `managedAccountRestricted` | `denied` |
| `operationCancelled` | `cancelled` |
| everything else (`networkUnavailable`, `quotaExceeded`, `serverRecordChanged`, `notFound`, `tooLarge`, `badArgs`, …) | `failed` |

`Error.retryAfter?` reads `retryAfter`. Availability: iOS and Mac Catalyst, signed with the iCloud
entitlement (`com.apple.developer.icloud-services` holding `CloudKit`, the container among
`com.apple.developer.icloud-container-identifiers`); without it every request is `missingEntitlement`
and CloudKit is never touched. -/

namespace ElmLean.Native.Client.CloudKit
open Lean ElmLean.Native.Client

/-- A field's value: a string, a number, a date (seconds since 1970), bytes, a list of those, an asset
(present, not its bytes) or a reference (a record name). -/
inductive Field where
  | str (s : String)
  | num (n : JsonNumber)
  | date (secondsSince1970 : Float)
  | bytes (b : ByteArray)
  | list (items : Array Field)
  | asset
  | ref (name : String)
  deriving Inhabited

partial def Field.toJson : Field → Json
  | .str s => Json.str s
  | .num n => Json.num n
  | .date d => Json.mkObj [("date", Lean.toJson d)]
  | .bytes b => Json.mkObj [("hex", Json.str (hexOf b))]
  | .list items => Json.arr (items.map Field.toJson)
  | .asset => Json.mkObj [("asset", Json.bool true)]
  | .ref n => Json.mkObj [("ref", Json.str n)]

partial def Field.ofJson (j : Json) : Result Field :=
  match j with
  | .str s => pure (.str s)
  | .num n => pure (.num n)
  | .arr items => return .list (← items.mapM Field.ofJson)
  | .obj _ => do
    if let some d ← optFloat j "date" then return .date d
    if let some b ← optHex j "hex" then return .bytes b
    if (← optBool j "asset") == some true then return .asset
    if let some n ← optString j "ref" then return .ref n
    throw (malformed s!"a field of unknown kind: {j.compress}")
  | _ => throw (malformed s!"a field of unknown kind: {j.compress}")

instance : BEq Field where
  beq a b := a.toJson == b.toJson

structure Record where
  name : String
  type : String
  fields : List (String × Field)
  /-- Seconds since 1970, when CloudKit gave one. -/
  modified : Option Float := none
  /-- The record's change tag. -/
  tag : Option String := none
  deriving Inhabited

def Record.field? (r : Record) (k : String) : Option Field := r.fields.lookup k

def Record.ofJson (j : Json) : Result Record := do
  let fields ← match j.getObjVal? "fields" with
    | .ok (.obj kvs) => kvs.toList.mapM fun (k, v) => return (k, ← Field.ofJson v)
    | _ => throw (malformed "a record without `fields`")
  return { name := ← reqString j "name", type := ← reqString j "type", fields,
           modified := ← optFloat j "modified", tag := ← optString j "tag" }

def errorKind (name : String) : Kind :=
  if name == "missingEntitlement" then .unsupported
  else if ["notAuthenticated", "permissionFailure", "managedAccountRestricted"].contains name then .denied
  else if name == "operationCancelled" then .cancelled
  else .failed

/-- An answer's error, if it carries one. -/
def error? (j : Json) : Result (Option Error) := do
  match ← optString j "error" with
  | none => pure none
  | some name => pure (some { kind := errorKind name, name, code := ← optInt j "code", detail := (← optString j "detail").getD "" })

def Error.retryAfter? (e : Error) : Option Float := (optFloat e.reply "retryAfter").toOption.join

def withErrors (decode : Json → Result α) (j : Json) : Result α := do
  if let some e ← error? j then throw e
  decode j

inductive AccountStatus where
  | available | noAccount | restricted | couldNotDetermine | temporarilyUnavailable
  deriving Repr, BEq, Inhabited

structure Account where
  status : AccountStatus
  /-- The account's user record name, when `available`. -/
  user : Option String
  deriving Repr, BEq, Inhabited

def containerArg (container : Option String) : List (String × Option Json) := [("container", container.map Json.str)]

def account (container : Option String := none) : Request Account :=
  { capability := "cloudkit.account", args := obj (containerArg container)
    decode := withErrors fun j => do
      let status ← match ← reqString j "status" with
        | "available" => pure AccountStatus.available
        | "noAccount" => pure .noAccount
        | "restricted" => pure .restricted
        | "couldNotDetermine" => pure .couldNotDetermine
        | "temporarilyUnavailable" => pure .temporarilyUnavailable
        | s => throw (malformed s!"account status {s}")
      let user ← optString j "user"
      if status == .available && user.isNone then throw (malformed "an available account without `user`")
      return { status, user } }

structure Query where
  type : String
  /-- Every one must hold. -/
  equals : List (String × Field) := []
  sortBy : Option String := none
  ascending : Bool := true
  /-- The fields to fetch; all when `none`. -/
  keys : Option (List String) := none
  /-- At most 500; the shell's default is 100. -/
  limit : Option Nat := none
  container : Option String := none

structure QueryResult where
  records : Array Record
  /-- More matched than `limit`. -/
  more : Bool

def query (q : Query) : Request QueryResult :=
  { capability := "cloudkit.query"
    args := obj ([("type", some (Json.str q.type)),
                  ("equals", if q.equals.isEmpty then none else some (Json.mkObj (q.equals.map fun (k, v) => (k, v.toJson)))),
                  ("sortBy", q.sortBy.map Json.str), ("ascending", some (Json.bool q.ascending)),
                  ("keys", q.keys.map fun ks => Json.arr (ks.toArray.map Json.str)), ("limit", q.limit.map toJson)] ++
                 containerArg q.container)
    decode := withErrors fun j => do
      let records ← match j.getObjVal? "records" with
        | .ok (.arr rs) => rs.mapM Record.ofJson
        | _ => throw (malformed "no `records`")
      return { records, more := (← optBool j "more").getD false } }

structure Save where
  type : String
  name : String
  fields : List (String × Field) := []
  asset : Option ByteArray := none
  assetField : Option String := none
  container : Option String := none

/-- Makes or updates the record; only the given fields change. -/
def save (s : Save) : Request Record :=
  { capability := "cloudkit.save"
    args := obj ([("type", some (Json.str s.type)), ("name", some (Json.str s.name)),
                  ("fields", if s.fields.isEmpty then none else some (Json.mkObj (s.fields.map fun (k, v) => (k, v.toJson)))),
                  ("asset", s.asset.map (Json.str ∘ hexOf)), ("assetField", s.assetField.map Json.str)] ++
                 containerArg s.container)
    decode := withErrors fun j => do
      unless ← reqBool j "ok" do throw (malformed "`ok` false without an error")
      match j.getObjVal? "record" with
      | .ok r => Record.ofJson r
      | .error _ => throw (malformed "no `record`") }

/-- The record and its asset's bytes (`none` when it has none). A missing record is `failed notFound`;
an asset over `maxBytes` is `failed tooLarge`. -/
def load (name : String) (maxBytes : Option Nat := none) (assetField : Option String := none)
    (container : Option String := none) : Request (Record × Option ByteArray) :=
  { capability := "cloudkit.load"
    args := obj ([("name", some (Json.str name)), ("maxBytes", maxBytes.map toJson), ("assetField", assetField.map Json.str)] ++
                 containerArg container)
    decode := withErrors fun j => do
      let record ← match j.getObjVal? "record" with
        | .ok r => Record.ofJson r
        | .error _ => throw (malformed "no `record`")
      return (record, ← optHex j "asset") }

/-- Deletes the record; also succeeds when there was none. -/
def delete (name : String) (container : Option String := none) : Request Unit :=
  { capability := "cloudkit.delete", args := obj ([("name", some (Json.str name))] ++ containerArg container)
    decode := withErrors fun j => do
      unless ← reqBool j "ok" do throw (malformed "`ok` false without an error") }

end ElmLean.Native.Client.CloudKit
