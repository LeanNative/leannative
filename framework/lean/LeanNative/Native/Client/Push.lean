import LeanNative.Native.Client

/-! # Apple's push notifications (`push.register/permission/ask/complete`)

Only for an app whose manifest says `push := true` and lists `push.*` in `uses`: no other app has any of
it (`LeanNativeShell.Push`).

| request | answer | result |
|---|---|---|
| `register` | `{"token":hex,"environment"}` | the device's token and which of Apple's gateways it is for |
| `permission` | `{"status"}` | whether notices may be shown |
| `ask` | `{"granted"}` | the system's question, put once; ask from something the person did |
| `complete tag result` | `{"ok"}` | iOS is told the app has done with a notice; `false` when it was answered already (`notPending`) |

An app's server sends by the token, to the gateway of its `environment`: a development build's token is
refused by the production gateway and the other way about.

**Events** (`App.system`, read with `event?`): `received` when a notice that carries `content-available`
arrives, waking the app if it is behind, to be answered with `complete` within about thirty seconds;
`expired` when the shell is about to answer for the app (twenty-four seconds); `presented` when a notice
arrives while the app is in front (nothing is shown); `opened` when a notice is tapped, whether the app was
running or the tap started it. One notice can be several of these (in front with `content-available`:
presented and received; woken and then tapped: received and opened), so an app does its work once. `payload` is the notice as the server sent it (`aps` and the server's own keys),
less whatever JSON cannot carry.

Errors: `missingEntitlement` is `unsupported` (the app has no `aps-environment`: Apple is not asked);
`failed` (Apple's refusal, with its code) and `timeout` (no word from Apple in thirty seconds) are `failed`.
All of this is a compatible extension of the shell's protocol: an app that does not ask is as before. -/

namespace LeanNative.Native.Client.Push
open Lean LeanNative.Native.Client

def errorKind (name : String) : Kind := if name == "missingEntitlement" then .unsupported else .failed

def withErrors (decode : Json → Result α) (j : Json) : Result α := do
  if let some name ← optString j "error" then
    -- `ok: false` with an error is an answer of its own (`complete`'s `notPending`), read by the decoder
    if (j.getObjVal? "ok").toOption != some (Json.bool false) then
      throw { kind := errorKind name, name, code := ← optInt j "code", detail := (← optString j "detail").getD "" }
  decode j

/-- Which of Apple's gateways a token is for. -/
inductive Environment where
  | development | production
  deriving Repr, BEq, Inhabited

def Environment.name : Environment → String
  | .development => "development"
  | .production => "production"

structure Token where
  /-- The token's bytes in hexadecimal, as Apple's gateways take it. -/
  hex : String
  environment : Environment
  deriving Repr, BEq, Inhabited

def register : Request Token :=
  { capability := "push.register", args := Json.mkObj []
    decode := withErrors fun j => do
      let hex ← reqString j "token"
      if hex.isEmpty || !hex.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')) || hex.length % 2 != 0 then throw (malformed "`token` is not hexadecimal")
      let environment ← match ← reqString j "environment" with
        | "development" => pure Environment.development
        | "production" => pure .production
        | s => throw (malformed s!"environment {s}")
      return { hex, environment } }

inductive Permission where
  | notDetermined | denied | authorized | provisional | ephemeral
  deriving Repr, BEq, Inhabited

def Permission.name : Permission → String
  | .notDetermined => "notDetermined" | .denied => "denied" | .authorized => "authorized"
  | .provisional => "provisional" | .ephemeral => "ephemeral"

/-- Whether a notice would be shown. -/
def Permission.shows : Permission → Bool
  | .authorized | .provisional | .ephemeral => true
  | .notDetermined | .denied => false

def permission : Request Permission :=
  { capability := "push.permission", args := Json.mkObj []
    decode := withErrors fun j => do
      match ← reqString j "status" with
      | "notDetermined" => pure Permission.notDetermined
      | "denied" => pure .denied
      | "authorized" => pure .authorized
      | "provisional" => pure .provisional
      | "ephemeral" => pure .ephemeral
      | s => throw (malformed s!"permission status {s}") }

/-- The system's question whether the app may show notices: whether the person said yes. -/
def ask (alert sound badge : Bool := true) : Request Bool :=
  { capability := "push.ask"
    args := obj [("alert", if alert then none else some (Json.bool false)), ("sound", if sound then none else some (Json.bool false)),
                 ("badge", if badge then none else some (Json.bool false))]
    decode := withErrors fun j => reqBool j "granted" }

/-- What the app made of a notice, as iOS wants it said. -/
inductive Outcome where
  | newData | noData | failed
  deriving Repr, BEq, Inhabited

def Outcome.name : Outcome → String
  | .newData => "newData" | .noData => "noData" | .failed => "failed"

/-- iOS told the app has done with the notice `tag`: `true`, or `false` when it was answered already. -/
def complete (tag : Nat) (result : Outcome := .noData) : Request Bool :=
  { capability := "push.complete", args := Json.mkObj [("tag", toJson tag), ("result", Json.str result.name)]
    decode := withErrors fun j => reqBool j "ok" }

/-- What the shell says of a notice (`App.system`). -/
inductive Event where
  /-- A notice arrived: answer `complete tag` within about thirty seconds. `state`: `active`, `inactive` or
  `background`. -/
  | received (tag : Nat) (state : String) (payload : Json)
  /-- The shell is about to answer for the app: stop, and `complete` now if it can still be said. -/
  | expired (tag : Nat)
  /-- A notice arrived while the app is in front; nothing was shown. -/
  | presented (payload : Json)
  /-- A notice was tapped. -/
  | opened (payload : Json)

/-- The push event in a system event, when it is one. -/
def event? (j : Json) : Option Event :=
  match j.getObjVal? "push", j.getObjVal? "pushExpired", j.getObjVal? "pushPresented", j.getObjVal? "pushOpened" with
  | .ok p, _, _, _ => do
    pure (.received (← (p.getObjValAs? Nat "tag").toOption) ((p.getObjValAs? String "state").toOption.getD "background") (p.getObjValD "payload"))
  | _, .ok p, _, _ => do pure (.expired (← (p.getObjValAs? Nat "tag").toOption))
  | _, _, .ok p, _ => some (.presented (p.getObjValD "payload"))
  | _, _, _, .ok p => some (.opened (p.getObjValD "payload"))
  | _, _, _, _ => none

end LeanNative.Native.Client.Push
