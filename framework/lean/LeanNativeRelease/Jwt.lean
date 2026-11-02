import Std.Time
import LeanNativeRelease.Run

/-! # App Store Connect API tokens

A token is an ES256 JWT that lives 20 minutes, signed with the team's API key (an `AuthKey_<id>.p8` file,
PKCS#8 P-256). `openssl dgst -sha256 -sign` makes the signature; it writes DER (r and s as ASN.1 integers)
and a JWT carries the two 32-byte big-endian numbers side by side (RFC 7518 §3.4), which `derToRaw`
converts. -/

namespace LeanNativeRelease.Jwt
open Lean

private def alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toList.toArray

/-- base64url without padding (RFC 4648 §5). -/
def base64url (b : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i < b.size do
    let n0 := b[i]!.toNat
    let n1 := if i + 1 < b.size then b[i + 1]!.toNat else 0
    let n2 := if i + 2 < b.size then b[i + 2]!.toNat else 0
    let n := (n0 <<< 16) ||| (n1 <<< 8) ||| n2
    let chars := min 4 (b.size - i + 1)
    for k in [0:chars] do
      out := out.push alphabet[(n >>> (18 - 6 * k)) &&& 63]!
    i := i + 3
  return out

/-- base64url back to bytes; none for a character outside the alphabet. -/
def unbase64url (s : String) : Option ByteArray := do
  let values ← s.toList.mapM fun c => alphabet.findIdx? (· == c)
  let mut out := ByteArray.empty
  let mut acc := 0
  let mut bits := 0
  for v in values do
    acc := (acc <<< 6) ||| v
    bits := bits + 6
    if bits ≥ 8 then
      bits := bits - 8
      out := out.push ((acc >>> bits) &&& 0xff).toUInt8
  return out

/-- An ECDSA-Sig-Value (`SEQUENCE { r INTEGER, s INTEGER }`) as r ‖ s, 32 bytes each. -/
def derToRaw (der : ByteArray) : Except String ByteArray := do
  let byte (i : Nat) : Except String Nat :=
    if h : i < der.size then pure der[i].toNat else throw "a truncated DER signature"
  let length (i : Nat) : Except String (Nat × Nat) := do
    let n ← byte i
    if n < 0x80 then return (n, i + 1)
    let mut v := 0
    for j in [0:n &&& 0x7f] do v := v * 256 + (← byte (i + 1 + j))
    return (v, i + 1 + (n &&& 0x7f))
  unless (← byte 0) == 0x30 do throw "not a DER sequence"
  let (_, start) ← length 1
  let mut i := start
  let mut out := ByteArray.empty
  for _ in [0:2] do
    unless (← byte i) == 0x02 do throw "not a DER integer"
    let (n, j) ← length (i + 1)
    unless j + n ≤ der.size do throw "a truncated DER signature"
    let value := ((der.extract j (j + n)).toList.dropWhile (· == 0)).toArray
    unless value.size ≤ 32 do throw "not a P-256 signature"
    out := out ++ ByteArray.mk (Array.replicate (32 - value.size) 0) ++ ByteArray.mk value
    i := j + n
  return out

def nowSeconds : IO Int := do
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

/-- The ES256 signature of `input` under the PEM key at `keyPath`, as r ‖ s. -/
def sign (keyPath : String) (input : ByteArray) : IO ByteArray := do
  let inFile ← tempFile input
  let sigFile ← tempFile .empty
  try
    discard <| run "openssl" #["dgst", "-sha256", "-sign", keyPath, "-out", sigFile.toString, inFile.toString]
    match derToRaw (← IO.FS.readBinFile sigFile) with
    | .ok raw => pure raw
    | .error e => fail s!"openssl's signature: {e}"
  finally
    IO.FS.removeFile inFile
    IO.FS.removeFile sigFile

/-- A token for the App Store Connect API: `kid` the key's id, `iss` the issuer, 20 minutes from now. -/
def mint (keyPath keyId issuer : String) (now : Option Int := none) : IO String := do
  let now ← match now with | some t => pure t | none => nowSeconds
  let header := Json.mkObj [("alg", "ES256"), ("kid", keyId), ("typ", "JWT")]
  let payload := Json.mkObj [("iss", issuer), ("iat", toJson now), ("exp", toJson (now + 20 * 60)),
    ("aud", "appstoreconnect-v1")]
  let signingInput := s!"{base64url header.compress.toUTF8}.{base64url payload.compress.toUTF8}"
  return s!"{signingInput}.{base64url (← sign keyPath signingInput.toUTF8)}"

end LeanNativeRelease.Jwt
