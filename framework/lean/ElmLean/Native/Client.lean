import Lean.Data.Json
import ElmLean.Native

/-! # ElmLean.Native.Client: typed requests and answers for the shell's capabilities

An optional native support module (import it, or one of `Client.Auth`, `Client.Keychain`, `Client.Http`,
`Client.CloudKit`, `Client.Bluetooth`). Each client builds a capability's arguments from a typed request
and reads its answer into a typed result or an `Error`, so an app need not write or inspect the JSON.
They speak the protocol of `ElmShell/Capabilities.lean` and `ElmShell/CloudKit.lean`; the raw
`Effects.ask` / `Effects.cap` stay, for anything a client does not cover.

Every failure is an `Error` of one `Kind`:

| kind | means |
|---|---|
| `denied` | the person or the system refused: authentication failed, Bluetooth not allowed, no iCloud account |
| `cancelled` | the person, the system or the app cancelled |
| `unsupported` | not available here: an unknown capability, the platform, the hardware, a missing entitlement |
| `malformed` | the answer is not of the documented shape; it never becomes a successful default |
| `failed` | the service ran and failed, as `name` (the shell's error name), `code`, `domain` and `detail` say |

and keeps the capability and the whole answer (`reply`) for diagnostics: an error name a client does not
know is a `failed` with that name, never dropped.

What a typed client does not do: it checks the shape of what the shell answers, not that the shell, iOS
or macOS did the right thing. The native implementations are trusted (see the README's "What is
trusted"); passing these clients' tests is not a proof of them. -/

namespace ElmLean.Native.Client
open Lean

/-- What kind of failure an answer is (see the module documentation). -/
inductive Kind where
  | denied
  | cancelled
  | unsupported
  | malformed
  | failed
  deriving Repr, BEq, Inhabited, DecidableEq

def Kind.name : Kind → String
  | .denied => "denied"
  | .cancelled => "cancelled"
  | .unsupported => "unsupported"
  | .malformed => "malformed"
  | .failed => "failed"

/-- A capability's failure. -/
structure Error where
  kind : Kind
  /-- The shell's error name (`timeout`, `notFound`, `userCancel`, `missingEntitlement`, `status -25308`, …),
  or `malformed` for an answer of the wrong shape. -/
  name : String
  /-- The native code, when there is one (an `OSStatus`, an `LAError`, a `CKErrorCode`, an `NSURLError`). -/
  code : Option Int := none
  /-- The native error domain, when the shell reports one. -/
  domain : Option String := none
  /-- Whatever text the shell or the system gave (not meant for people: it may be English, or empty). -/
  detail : String := ""
  /-- The capability asked. -/
  capability : String := ""
  /-- The shell's whole answer. -/
  reply : Json := Json.null
  deriving BEq, Inhabited

instance : ToString Error where
  toString e :=
    let code := match e.code with | some c => s!" {c}" | none => ""
    let detail := if e.detail.isEmpty then "" else s!": {e.detail}"
    s!"{e.capability}: {e.kind.name} ({e.name}{code}){detail}"

abbrev Result (α : Type) := Except Error α

/-- An answer that is not of the documented shape. -/
def malformed (what : String) : Error := { kind := .malformed, name := "malformed", detail := what }

def failed (name : String) (detail : String := "") (code : Option Int := none) : Error :=
  { kind := .failed, name, detail, code }

/-! ## Reading answers -/

/-- A string field, or `none` when absent or `null`; a field of another type is malformed. -/
def optString (j : Json) (k : String) : Result (Option String) :=
  match j.getObjVal? k with
  | .error _ | .ok .null => pure none
  | .ok (.str s) => pure (some s)
  | .ok _ => throw (malformed s!"`{k}` is not a string")

def reqString (j : Json) (k : String) : Result String := do
  match ← optString j k with
  | some s => pure s
  | none => throw (malformed s!"no `{k}`")

def optBool (j : Json) (k : String) : Result (Option Bool) :=
  match j.getObjVal? k with
  | .error _ | .ok .null => pure none
  | .ok (.bool b) => pure (some b)
  | .ok _ => throw (malformed s!"`{k}` is not a boolean")

def reqBool (j : Json) (k : String) : Result Bool := do
  match ← optBool j k with
  | some b => pure b
  | none => throw (malformed s!"no `{k}`")

/-- An integer field (`1.0` is accepted, `1.5` is not). -/
def optInt (j : Json) (k : String) : Result (Option Int) :=
  match j.getObjVal? k with
  | .error _ | .ok .null => pure none
  | .ok v => match v.getInt? with
    | .ok n => pure (some n)
    | .error _ => throw (malformed s!"`{k}` is not an integer")

def reqInt (j : Json) (k : String) : Result Int := do
  match ← optInt j k with
  | some n => pure n
  | none => throw (malformed s!"no `{k}`")

def reqNat (j : Json) (k : String) : Result Nat := do
  let n ← reqInt j k
  if n < 0 then throw (malformed s!"`{k}` is negative") else pure n.toNat

def optFloat (j : Json) (k : String) : Result (Option Float) :=
  match j.getObjVal? k with
  | .error _ | .ok .null => pure none
  | .ok (.num n) => pure (some n.toFloat)
  | .ok _ => throw (malformed s!"`{k}` is not a number")

def hexOf (b : ByteArray) : String :=
  let digit (n : UInt8) : Char := "0123456789abcdef".toList[n.toNat]!
  String.ofList (b.toList.flatMap fun (x : UInt8) => [digit (x >>> 4), digit (x &&& 15)])

def bytesOfHex? (s : String) : Option ByteArray :=
  let nib (c : Char) : Option UInt8 :=
    if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat).toUInt8
    else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10).toUInt8
    else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10).toUInt8
    else none
  let rec go : List Char → ByteArray → Option ByteArray
    | [], acc => some acc
    | a :: b :: rest, acc => do go rest (acc.push (((← nib a) <<< 4) ||| (← nib b)))
    | [_], _ => none
  go s.toList ByteArray.empty

def reqHex (j : Json) (k : String) : Result ByteArray := do
  match bytesOfHex? (← reqString j k) with
  | some b => pure b
  | none => throw (malformed s!"`{k}` is not hex")

def optHex (j : Json) (k : String) : Result (Option ByteArray) := do
  match ← optString j k with
  | none => pure none
  | some s => match bytesOfHex? s with
    | some b => pure (some b)
    | none => throw (malformed s!"`{k}` is not hex")

/-! ## Asking -/

/-- The shell's answer to a capability it does not have (an older shell, or a name it never offered). -/
def unknownCapability? (reply : Json) : Option Error :=
  match reply.getObjValAs? String "error" with
  | .ok e => if e.startsWith "unknown capability" then some { kind := .unsupported, name := "unknownCapability", detail := e } else none
  | .error _ => none

/-- Reads `reply`, the answer to `capability`, with `decode`; every error carries both. -/
def decodeReply (capability : String) (reply : Json) (decode : Json → Result α) : Result α :=
  let r : Result α := match unknownCapability? reply with
    | some e => .error e
    | none => if reply matches .obj _ then decode reply else .error (malformed "the answer is not an object")
  r.mapError fun e => { e with capability, reply }

/-- Asks for `capability` and returns a task with its typed result (any thread; do not wait on it from
the shell's main thread). -/
def request (fx : Effects Host) (capability : String) (args : Json) (decode : Json → Result α) :
    IO (Task (Result α)) := do
  return (← fx.ask capability args).map (decodeReply capability · decode)

/-- Asks for `capability` and waits for its typed result (not from the shell's main thread). -/
def call (fx : Effects Host) (capability : String) (args : Json) (decode : Json → Result α) : IO (Result α) := do
  IO.wait (← request fx capability args decode)

/-- A request: the capability, its arguments, and how its answer reads. `call`/`request` run one; tests
and apps can inspect `args` without running it. -/
structure Request (α : Type) where
  capability : String
  args : Json
  decode : Json → Result α

def Request.call (r : Request α) (fx : Effects Host) : IO (Result α) := Client.call fx r.capability r.args r.decode
def Request.run (r : Request α) (fx : Effects Host) : IO (Task (Result α)) := request fx r.capability r.args r.decode
/-- Reads an answer to this request (what `call` does once the shell answers). -/
def Request.read (r : Request α) (reply : Json) : Result α := decodeReply r.capability reply r.decode

/-- `Json.mkObj` without the `none` fields. -/
def obj (fields : List (String × Option Json)) : Json :=
  Json.mkObj (fields.filterMap fun (k, v) => v.map (k, ·))

end ElmLean.Native.Client
