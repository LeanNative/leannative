import LeanNativeRelease

/-! # The release tool on this Mac

What the release workflow relies on, against the real tools: a token minted with a P-256 key that openssl
made verifies under openssl with the key's public half, and its header and claims are App Store Connect's; the
policy takes stable tags and What to Test up to 4,000 characters; and a small arm64 app, signed ad hoc with
the entitlements of a distribution build, passes `verifyApp` and `verifyIpa` while one signed for another team
or with debugging on does not. (App Store Connect itself is reached only by a release, or by
`leannative-release testflight check`.) -/

open LeanNativeRelease Lean

initialize checks : IO.Ref (Nat × Nat) ← IO.mkRef (0, 0)

def check (name : String) (ok : Bool) (detail : String := "") : IO Unit := do
  checks.modify fun (p, f) => if ok then (p + 1, f) else (p, f + 1)
  IO.println s!"{if ok then "PASS" else "FAIL"} {name}{if ok || detail.isEmpty then "" else ": " ++ detail}"

/-- Whether `act` fails with a message containing `part`. -/
def failsWith (act : IO Unit) (part : String) : IO Bool := do
  try act; return false catch e => return (toString e).contains part

def bytes (l : List Nat) : ByteArray := ByteArray.mk (l.map (·.toUInt8)).toArray

/-- r ‖ s as DER, for openssl to verify. -/
def rawToDer (raw : ByteArray) : ByteArray :=
  let int (v : ByteArray) : ByteArray :=
    let trimmed := (v.toList.dropWhile (· == 0)).toArray
    let body := if trimmed.isEmpty || trimmed[0]! ≥ 0x80 then #[0] ++ trimmed else trimmed
    bytes [0x02, body.size] ++ ByteArray.mk body
  let seq := int (raw.extract 0 32) ++ int (raw.extract 32 64)
  bytes [0x30, seq.size] ++ seq

def jwtChecks (dir : System.FilePath) : IO Unit := do
  check "base64url: RFC 4648's vectors" ([("f", "Zg"), ("fo", "Zm8"), ("foo", "Zm9v"), ("foob", "Zm9vYg"),
    ("fooba", "Zm9vYmE"), ("foobar", "Zm9vYmFy")].all fun (i, o) => Jwt.base64url i.toUTF8 == o)
  check "base64url: the URL alphabet" (Jwt.base64url (bytes [0xfb, 0xff]) == "-_8")
  check "base64url: decodes what it encodes"
    ((List.range 40).all fun n => Jwt.unbase64url (Jwt.base64url (bytes ((List.range n).map (· * 37 % 256)))) ==
      some (bytes ((List.range n).map (· * 37 % 256))))
  let high := (List.range 32).map fun i => 0x80 + i
  let short := (List.range 31).map (· + 1)
  let der := bytes ([0x30, 2 + 33 + 2 + 31, 0x02, 33, 0] ++ high ++ [0x02, 31] ++ short)
  check "DER: a leading zero dropped, a short integer padded"
    ((Jwt.derToRaw der).toOption == some (bytes (high ++ [0] ++ short)))
  check "DER: not a sequence" (Jwt.derToRaw (bytes [0x31, 0]) matches .error _)
  check "DER: truncated" (Jwt.derToRaw (bytes [0x30, 6, 0x02, 4, 1]) matches .error _)
  -- a key like App Store Connect's AuthKey .p8: PKCS#8 P-256
  let pem := dir / "ec.pem"
  let p8 := dir / "AuthKey_TEST.p8"
  let pub := dir / "pub.pem"
  discard <| run "openssl" #["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", pem.toString]
  discard <| run "openssl" #["pkcs8", "-topk8", "-nocrypt", "-in", pem.toString, "-out", p8.toString]
  discard <| run "openssl" #["ec", "-in", pem.toString, "-pubout", "-out", pub.toString]
  let token ← Jwt.mint p8.toString "TESTKEY123" "issuer-uuid" (now := some 1700000000)
  let parts := token.splitOn "."
  check "jwt: three parts" (parts.length == 3)
  let some [header, claims, sig] := parts.mapM Jwt.unbase64url | check "jwt: base64url parts" false; return
  let header := Json.parse (String.fromUTF8! header)
  let claims := Json.parse (String.fromUTF8! claims)
  check "jwt: ES256 header with the key id"
    (header.toOption == some (Json.mkObj [("alg", "ES256"), ("kid", "TESTKEY123"), ("typ", "JWT")])) s!"{header.map (·.compress)}"
  check "jwt: issuer, audience, 20 minutes"
    (claims.toOption == some (Json.mkObj [("iss", "issuer-uuid"), ("iat", (1700000000 : Int)), ("exp", (1700001200 : Int)),
      ("aud", "appstoreconnect-v1")])) s!"{claims.map (·.compress)}"
  check "jwt: a 64-byte signature" (sig.size == 64)
  let input := dir / "input"
  IO.FS.writeFile input (".".intercalate (parts.take 2))
  IO.FS.writeBinFile (dir / "sig.der") (rawToDer sig)
  let verified ← run "openssl" #["dgst", "-sha256", "-verify", pub.toString, "-signature", (dir / "sig.der").toString,
    input.toString] (check := false)
  check "jwt: openssl verifies the signature with the public key" (verified.exitCode == 0 && verified.stdout.contains "Verified OK")
    (trim (verified.stdout ++ verified.stderr))
  -- the signature covers the input: another input does not verify
  IO.FS.writeFile input ("x" ++ ".".intercalate (parts.take 2))
  let tampered ← run "openssl" #["dgst", "-sha256", "-verify", pub.toString, "-signature", (dir / "sig.der").toString,
    input.toString] (check := false)
  check "jwt: a changed input does not verify" (tampered.exitCode != 0)

def policyChecks (dir : System.FilePath) : IO Unit := do
  check "tags: stable ones" (["v0.0.0", "v0.9.10", "v1.2.3", "v10.20.30"].all isStableTag)
  check "tags: others refused" (!["0.9.10", "v0.9", "v0.9.10.1", "v01.2.3", "v1.2.3-rc1", "v1..3", "v", "V1.2.3"].any isStableTag)
  let notes := dir / "notes.txt"
  IO.FS.writeFile notes (String.ofList (List.replicate 4000 'a') ++ "\n\n  \n")
  check "notes: 4,000 characters and trailing whitespace pass" ((← notesText notes).length == 4000)
  IO.FS.writeFile notes (String.ofList (List.replicate 4001 'é'))
  check "notes: 4,001 characters (not bytes) refused" (← failsWith (discard <| notesText notes) "4001 characters")
  IO.FS.writeFile notes " \n\n"
  check "notes: blank refused" (← failsWith (discard <| notesText notes) "missing or empty")
  check "notes: missing refused" (← failsWith (discard <| notesText (dir / "none.txt")) "missing or empty")
  IO.FS.writeFile notes "What to Test.\n\n"
  appendNotes notes "Peers: census abc  "
  check "append-notes: a last paragraph" ((← IO.FS.readFile notes) == "What to Test.\n\nPeers: census abc\n")
  check "policy: a bad tag" (← failsWith (policy notes (some "v1.2")) "stable vMAJOR.MINOR.PATCH")

def infoPlist (bundle version build : String) : String := s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>CFBundleIdentifier</key><string>{bundle}</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
<key>CFBundleVersion</key><string>{build}</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>
</dict></plist>
"

def entitlementsPlist (team bundle : String) (debuggable : Bool) : String := s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>application-identifier</key><string>{team}.{bundle}</string>
<key>com.apple.developer.team-identifier</key><string>{team}</string>
<key>get-task-allow</key><{if debuggable then "true" else "false"}/>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.{bundle}</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>Production</string>
</dict></plist>
"

/-- A signed `Probe.app` under `dir`: an arm64 executable, Info.plist, and the given entitlements. -/
def probeApp (dir : System.FilePath) (team : String) (debuggable : Bool) : IO System.FilePath := do
  let app := dir / "Payload" / "Probe.app"
  if ← app.pathExists then IO.FS.removeDirAll app
  IO.FS.createDirAll app
  IO.FS.writeFile (dir / "probe.c") "int main(void) { return 0; }\n"
  discard <| run "xcrun" #["clang", "-arch", "arm64", "-o", (app / "Probe").toString, (dir / "probe.c").toString]
  IO.FS.writeFile (app / "Info.plist") (infoPlist "com.example.probe" "1.2.3" "42")
  IO.FS.writeFile (dir / "ent.plist") (entitlementsPlist team "com.example.probe" debuggable)
  discard <| run "codesign" #["--force", "-s", "-", "--entitlements", (dir / "ent.plist").toString, app.toString]
  return app

def bundleChecks (dir : System.FilePath) : IO Unit := do
  let id : Identity := { bundleId := "com.example.probe", teamId := "TEAM123456", version := "1.2.3", build := "42",
                         icloudContainer := some "iCloud.com.example.probe" }
  let app ← probeApp dir "TEAM123456" false
  check "verify-app: a distribution build passes" (!(← failsWith (verifyApp app id true) ""))
  check "verify-app: another version" (← failsWith (verifyApp app { id with version := "1.2.4" } true) "app version 1.2.3, not 1.2.4")
  check "verify-app: another build number" (← failsWith (verifyApp app { id with build := "43" } true) "build number 42, not 43")
  check "verify-app: another bundle" (← failsWith (verifyApp app { id with bundleId := "com.example.other" } true) "app bundle")
  check "verify-app: another iCloud container"
    (← failsWith (verifyApp app { id with icloudContainer := some "iCloud.other" } true) "iCloud container")
  -- the archive is signed for development before export; Xcode chooses the environment then
  let archived ← probeApp dir "TEAM123456" true
  check "verify-app: a development archive passes as an archive" (!(← failsWith (verifyApp archived id false) ""))
  check "verify-app: debugging on is not distribution" (← failsWith (verifyApp archived id true) "disable debugging")
  let otherTeam ← probeApp dir "OTHERTEAM1" false
  check "verify-app: signed for another team" (← failsWith (verifyApp otherTeam id true) "signed as OTHERTEAM1.com.example.probe")
  let app ← probeApp dir "TEAM123456" false
  let ipa := dir / "Probe.ipa"
  discard <| run "ditto" #["-c", "-k", "--keepParent", (dir / "Payload").toString, ipa.toString]
  check "verify-ipa: the package's app passes" (!(← failsWith (verifyIpa ipa id) ""))
  let recorded ← IO.FS.readFile (ipa.toString ++ ".verified.sha256")
  let sum ← run "shasum" #["-a", "256", ipa.toString]
  check "verify-ipa: the package's SHA-256 recorded" (recorded == sum.stdout && recorded.length > 64)
  IO.FS.writeFile (app / "Info.plist") (infoPlist "com.example.probe" "1.2.3" "42" ++ " ")
  check "verify-app: a bundle changed after signing" (← failsWith (verifyApp app id true) "codesign")

def main : IO UInt32 := do
  let dir ← IO.FS.createTempDir
  try
    policyChecks dir
    jwtChecks dir
    bundleChecks dir
  catch e => check "no step throws" false (toString e)
  IO.FS.removeDirAll dir
  let (passed, failed) ← checks.get
  IO.println s!"release-test: {passed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
