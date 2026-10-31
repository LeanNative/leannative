import LeanNative.Native.Client.Http

/-! # HTTP request (`http.request`)

A request with a method, headers and a body, on the same ephemeral session and redirect policy as
`http.get`, answered and decoded as `Http.get` is. Errors of its own, all `failed`: `bad-method` (not
GET, POST, PUT, PATCH or DELETE), `bad-headers` (not string keys and values, or a newline in one),
`bad-body` (not hex, or over 1 MiB) and `bad-size` (a negative `maxBytes`).

It is a module apart from `Http` because an app's manifest must list every capability its imported C
names (`Manifest.callProblems`): an app that imports only `Http` for `get` keeps `uses` at `http.get`. -/

namespace LeanNative.Native.Client.Http
open Lean LeanNative.Native.Client

/-- An HTTP request with an optional binary body. Header values are supplied by the caller; the shell
uses an ephemeral URLSession and applies the same redirect policy as `get`. -/
structure SendRequest where
  url : String
  httpMethod : String := "GET"
  headers : List (String × String) := []
  body : Option ByteArray := none
  maxBytes : Nat := 1_000_000
  timeout : Option Nat := none
  socks : Option (String × Nat) := none
  deriving Inhabited

def SendRequest.args (r : SendRequest) : Json :=
  Json.mkObj
    ([("url", Json.str r.url), ("maxBytes", toJson r.maxBytes), ("method", Json.str r.httpMethod),
     ("headers", Json.mkObj (r.headers.map fun (k, v) => (k, Json.str v)))] ++
    (r.body.map fun b => [("body", Json.str (hexOf b))]).getD [] ++
    (r.timeout.map fun t => [("timeout", toJson t)]).getD [] ++
    (r.socks.map fun (h, p) => [("socks", Json.mkObj [("host", Json.str h), ("port", toJson p)])]).getD [])

def send (r : SendRequest) : Client.Request Response :=
  { capability := "http.request", args := r.args, decode }

end LeanNative.Native.Client.Http
