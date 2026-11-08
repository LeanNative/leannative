import LeanNative.Native.Client

/-! # A sign-in in the system browser (`webauth`)

`start r` opens `r.url` in an `ASWebAuthenticationSession` and answers the URL the sign-in came back to
(`{"ok":true,"url":…}`): an OAuth authorization code flow's callback, query string and all, which the app
then reads itself. The callback is either https (`.https host path`: iOS 17.4 and later, and `host` must be
among the app's `webcredentials:` associated domains, with that host serving an `apple-app-site-association`
naming the app) or a custom scheme (`.scheme s`). Unless `ephemeral`, the sheet shares the browser's cookies,
so a person already signed in to the identity provider may be through without typing anything.

| `name` | kind |
|---|---|
| `canceledLogin` | `cancelled` (the person closed the sheet) |
| `unsupported` | `unsupported` (an https callback below iOS 17.4) |
| `presentationContextNotProvided`, `presentationContextInvalid`, `bad-url`, `bad-callback`, `busy`, anything else | `failed` |

Availability: iOS and Mac Catalyst. One sign-in at a time: a second `start` while one is open answers `busy`. -/

namespace LeanNative.Native.Client.WebAuth
open Lean LeanNative.Native.Client

inductive Callback where
  /-- An https callback the system hands back to the app (iOS 17.4+, `webcredentials:<host>`). -/
  | https (host path : String)
  /-- A custom URL scheme the app registers. -/
  | scheme (s : String)
  deriving Repr, BEq, Inhabited

structure Request where
  url : String
  callback : Callback
  /-- No shared cookies: the sign-in starts from nothing. -/
  ephemeral : Bool := false
  deriving Repr, BEq, Inhabited

def Request.args (r : Request) : Json :=
  obj ([("url", some (Json.str r.url))] ++
    (match r.callback with
     | .https host path => [("callbackHost", some (Json.str host)), ("callbackPath", some (Json.str path))]
     | .scheme s => [("callbackScheme", some (Json.str s))]) ++
    [("ephemeral", if r.ephemeral then some (Json.bool true) else none)])

def kindOf (name : String) : Kind :=
  if name == "canceledLogin" then .cancelled
  else if name == "unsupported" then .unsupported
  else .failed

/-- `{"ok":true,"url":…}`, or the error with its name. -/
def decode (j : Json) : Result String := do
  if ← reqBool j "ok" then
    return ← reqString j "url"
  let name := (← optString j "name").getD "unknown"
  throw { kind := kindOf name, name, code := ← optInt j "code", domain := ← optString j "domain", detail := (← optString j "error").getD "" }

/-- The sign-in; the result is the callback URL. -/
def start (r : Request) : Client.Request String :=
  { capability := "webauth", args := r.args, decode }

end LeanNative.Native.Client.WebAuth
