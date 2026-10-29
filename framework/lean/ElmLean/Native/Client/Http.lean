import ElmLean.Native.Client

/-! # HTTPS fetch (`http.get`)

One GET on an ephemeral session (no cookies or cache), redirects only within the same host and never
from https to http; with `socks`, through that SOCKS5 proxy only (names resolved by the proxy, no
direct fallback). The shell answers `{"status":n,"body":hex}` or `{"error":name}`:

| `error` | means | kind |
|---|---|---|
| `bad-url` | not an http(s) URL | `failed` |
| `bad-proxy` | `socks` is not a host and a port in 1…65535 | `failed` |
| `tooLarge` | the body is over `maxBytes` | `failed` |
| `response` | no HTTP response | `failed` |
| the system's text, with `code` and `domain` | the `NSError` (`NSURLErrorDomain`, …) | `cancelled` for `NSURLErrorCancelled` (-999), else `failed` named `system` |

`code` and `domain` on a system error are a compatible extension (`error` is its text, as before). A
response is a response whatever its status: a 404 is `.ok { status := 404, … }`.

Availability: iOS and Mac Catalyst. Plain http needs an App Transport Security exception in the app's
Info.plist (the system then answers its own error, code -1022). -/

namespace ElmLean.Native.Client.Http
open Lean ElmLean.Native.Client

structure Request where
  url : String
  maxBytes : Nat := 1_000_000
  /-- Seconds; the shell's default is 30, or 90 through a proxy. -/
  timeout : Option Nat := none
  accept : Option String := none
  /-- A SOCKS5 proxy, `(host, port)`. -/
  socks : Option (String × Nat) := none
  deriving Repr, BEq, Inhabited

structure Response where
  status : Nat
  body : ByteArray

instance : Repr Response where
  reprPrec r _ := s!"\{ status := {r.status}, body := {r.body.size} bytes }"

def Request.args (r : Request) : Json :=
  obj [("url", some (Json.str r.url)), ("maxBytes", some (toJson r.maxBytes)), ("timeout", r.timeout.map toJson),
       ("accept", r.accept.map Json.str),
       ("socks", r.socks.map fun (h, p) => Json.mkObj [("host", Json.str h), ("port", toJson p)])]

def named : List String := ["bad-url", "bad-proxy", "tooLarge", "response"]

def decode (j : Json) : Result Response := do
  match ← optString j "error" with
  | some e =>
    let code ← optInt j "code"
    let domain ← optString j "domain"
    if domain.isNone && named.contains e then throw (failed e)
    match domain with
    | some d =>
      let kind := if d == "NSURLErrorDomain" && code == some (-999) then Kind.cancelled else .failed
      throw { kind, name := "system", code, domain := some d, detail := e }
    -- an error the shell did not name and no domain: kept as it came
    | none => throw { kind := .failed, name := e, code }
  | none => return { status := ← reqNat j "status", body := ← reqHex j "body" }

def get (r : Request) : Client.Request Response :=
  { capability := "http.get", args := r.args, decode }

end ElmLean.Native.Client.Http
