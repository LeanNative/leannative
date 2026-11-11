import LeanNativeRelease

/-! # The release tool on this Mac

What the release workflow relies on, against the real tools: a token minted with a P-256 key that openssl
made verifies under openssl with the key's public half, and its header and claims are App Store Connect's; the
policy takes stable tags and What to Test up to 4,000 characters; and a small arm64 app, signed ad hoc with
the entitlements of a distribution build, passes `verifyApp` and `verifyIpa` while one signed for another team
or with debugging on does not.

App Store Connect is `framework/scripts/fake_asc.py` here, a local server holding one app's records: every
`testflight` step but `upload` runs against it through curl with no pauses, both the first time (it writes)
and again (it finds the work done), with a refusal `retrying` gets past, a build still processing, notes
that come back different, a build that never appears; each request carries a token that verifies with the
key, and the steps that only read send no write. `leannative-release testflight check` runs too, configured
by the environment. `upload` (`xcrun altool`) and the real API are reached only by a release.

    release-test [python] [fake_asc.py]     python3 and ../scripts/fake_asc.py by default -/

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

/-- Whether openssl verifies `token`'s signature with the public key `jwtChecks` left in `dir`. -/
def tokenVerifies (dir : System.FilePath) (token : String) : IO Bool := do
  let parts := token.splitOn "."
  let some sig := parts[2]?.bind Jwt.unbase64url | return false
  IO.FS.writeFile (dir / "input") (".".intercalate (parts.take 2))
  IO.FS.writeBinFile (dir / "sig.der") (rawToDer sig)
  let out ← run "openssl" #["dgst", "-sha256", "-verify", (dir / "pub.pem").toString, "-signature",
    (dir / "sig.der").toString, (dir / "input").toString] (check := false)
  return out.exitCode == 0 && out.stdout.contains "Verified OK"

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

def infoPlist (bundle version build : String) (extra : String := "") : String := s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>CFBundleIdentifier</key><string>{bundle}</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
<key>CFBundleVersion</key><string>{build}</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>{extra}
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

/-- A signed `Probe.app` under `dir`: an arm64 executable, Info.plist, and the given entitlements. With
`swift`, the executable links the system's Swift library; `declared` are its Info.plist's `LNSwiftSources`. -/
def probeApp (dir : System.FilePath) (team : String) (debuggable : Bool) (swift : Bool := false)
    (declared : List String := []) : IO System.FilePath := do
  let app := dir / "Payload" / "Probe.app"
  if ← app.pathExists then IO.FS.removeDirAll app
  IO.FS.createDirAll app
  IO.FS.writeFile (dir / "probe.c") "int main(void) { return 0; }\n"
  let swiftLib ← if swift then do
      let sdk ← run "xcrun" #["--show-sdk-path"]
      pure #[s!"-L{trim sdk.stdout}/usr/lib/swift", "-lswiftCore"]
    else pure #[]
  discard <| run "xcrun" (#["clang", "-arch", "arm64", "-o", (app / "Probe").toString, (dir / "probe.c").toString] ++ swiftLib)
  let sources := if declared.isEmpty then "" else
    s!"\n<key>{swiftSourcesKey}</key><array>{"".intercalate (declared.map (s!"<string>{·}</string>"))}</array>"
  IO.FS.writeFile (app / "Info.plist") (infoPlist "com.example.probe" "1.2.3" "42" sources)
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
  -- Swift: none unless the app declares its sources, then the system's libraries only, and none bundled
  let core := "/usr/lib/swift/libswiftCore.dylib"
  check "swift: the libraries otool lists, by install name"
    (swiftLibraries s!"/tmp/swift/Probe:\n\t{core} (compatibility version 0.0.0, current version 0.0.0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n\t@rpath/libswift_Concurrency.dylib (compatibility version 1.0.0)\n"
      == [core, "@rpath/libswift_Concurrency.dylib"])
  check "swift: none linked, none declared" (swiftProblems [] [] []).isEmpty
  check "swift: linked but not declared" ((swiftProblems [] [core] []).any (·.contains swiftSourcesKey))
  check "swift: declared, the system's libraries" (swiftProblems ["Bridge.swift"] [core, "/System/Library/Frameworks/SwiftUI.framework/SwiftUI"] []).isEmpty
  check "swift: declared, a library that is not the system's"
    ((swiftProblems ["Bridge.swift"] [core, "@rpath/libswiftCore.dylib"] []).any (·.contains "not the system's (@rpath/libswiftCore.dylib)"))
  check "swift: declared, a bundled library all the same"
    ((swiftProblems ["Bridge.swift"] [core] ["libswiftCore.dylib"]).any (·.contains "bundles a Swift library (libswiftCore.dylib)"))
  let undeclared ← probeApp dir "TEAM123456" false (swift := true)
  check "verify-app: Swift linked without a declaration" (← failsWith (verifyApp undeclared id true) "links a Swift library (/usr/lib/swift/libswiftCore.dylib)")
  let bridged ← probeApp dir "TEAM123456" false (swift := true) (declared := ["Bridge.swift"])
  check "verify-app: Swift linked, its sources declared" (!(← failsWith (verifyApp bridged id true) ""))
  let app ← probeApp dir "TEAM123456" false
  let ipa := dir / "Probe.ipa"
  discard <| run "ditto" #["-c", "-k", "--keepParent", (dir / "Payload").toString, ipa.toString]
  check "verify-ipa: the package's app passes" (!(← failsWith (verifyIpa ipa id) ""))
  let recorded ← IO.FS.readFile (ipa.toString ++ ".verified.sha256")
  let sum ← run "shasum" #["-a", "256", ipa.toString]
  check "verify-ipa: the package's SHA-256 recorded" (recorded == sum.stdout && recorded.length > 64)
  IO.FS.writeFile (app / "Info.plist") (infoPlist "com.example.probe" "1.2.3" "42" ++ " ")
  check "verify-app: a bundle changed after signing" (← failsWith (verifyApp app id true) "codesign")

/-! ## App Store Connect against the fake -/

def fakeStdio : IO.Process.StdioConfig := { stdin := .piped, stdout := .piped, stderr := .inherit }

/-- `fake_asc.py` started, and its port. It exits when its stdin closes, so a crash here leaves no server. -/
def startFake (python script : String) : IO (IO.Process.Child fakeStdio × Nat) := do
  let child ← IO.Process.spawn { fakeStdio with cmd := python, args := #["-I", script] }
  let line ← child.stdout.getLine
  let some port := (trim line).toNat? | fail s!"fake_asc.py printed {line.quote}, not its port"
  return (child, port)

/-- A request to the fake's own /_fake endpoints. -/
def fakeCall (port : Nat) (method path : String) (body : Json := .null) : IO Json := do
  let f ← tempFile body.compress.toUTF8
  let out ← try run "curl" #["-sS", "--fail-with-body", "-X", method, "-H", "Content-Type: application/json",
      "--data-binary", s!"@{f}", s!"http://127.0.0.1:{port}{path}"]
    finally IO.FS.removeFile f
  IO.ofExcept (Json.parse out.stdout)

/-- The default records with `over`'s keys over them, and an empty request log. -/
def reset (port : Nat) (over : List (String × Json) := []) : IO Unit :=
  discard <| fakeCall port "POST" "/_fake/reset" (Json.mkObj over)

def requests (port : Nat) : IO (Array Json) := do
  return arrOf ((← fakeCall port "GET" "/_fake/requests").getObjValD "requests")

def line (r : Json) : String := s!"{strOf (r.getObjValD "method")} {strOf (r.getObjValD "path")}"
def writes (rs : Array Json) : Array Json := rs.filter fun r => strOf (r.getObjValD "method") != "GET"

/-- A step's output (stdout and stderr) and the requests it made; its error when it failed. -/
def runStep (port : Nat) (c : Asc.Config) (step : String) : IO (String × Option String × Array Json) := do
  let before := (← requests port).size
  let (out, err) ← IO.FS.withIsolatedStreams (try c.step step; pure none catch e => pure (some (toString e)))
  return (out, err, (← requests port).extract before)

/-- Runs `step`, which must succeed and print `says`; the requests it made. -/
def passes (port : Nat) (c : Asc.Config) (name step : String) (says : List String) : IO (Array Json) := do
  let (out, err, rs) ← runStep port c step
  check name (err.isNone && says.all fun s => out.contains s) s!"{err.getD ""}\n{trim out}"
  return rs

/-- Runs `step`, which must fail with a message containing `part`; the requests it made. -/
def refuses (port : Nat) (c : Asc.Config) (name step part : String) : IO (Array Json) := do
  let (out, err, rs) ← runStep port c step
  check name ((err.getD "").contains part) s!"{err.getD "it passed"}\n{trim out}"
  return rs

def faults (fs : List (String × String × Nat × Nat)) : Json :=
  Json.arr (fs.toArray.map fun (method, path, status, times) =>
    Json.mkObj [("method", method), ("path", path), ("status", status), ("times", times)])

def body (r : Json) (path : List String) : String := strOf (at? (r.getObjValD "body") path)

def app : Json := Json.arr #[Json.mkObj [("id", "APP1"), ("bundleId", "com.example.probe"), ("name", "Probe"),
  ("sku", "PROBE1")]]
def bundleIds : Json := Json.arr #[Json.mkObj [("id", "BUNDLE1"), ("identifier", "com.example.probe"),
  ("name", "Probe")]]

/-- Each request went to /v1 with a token for the key and issuer that openssl verifies with the key. -/
def tokenChecks (dir : System.FilePath) (name : String) (rs : Array Json) : IO Unit := do
  let mut bad : Array String := #[]
  for r in rs do
    let auth := strOf (r.getObjValD "authorization")
    let token := ((auth.dropPrefix? "Bearer ").map (·.toString)).getD ""
    let part (i : Nat) (k : String) : String :=
      match (token.splitOn ".")[i]?.bind Jwt.unbase64url with
      | some b => match String.fromUTF8? b with
        | some t => (Json.parse t).toOption.map (fun j => strOf (j.getObjValD k)) |>.getD ""
        | none => ""
      | none => ""
    unless (strOf (r.getObjValD "path")).startsWith "/v1/" && (← tokenVerifies dir token) &&
        part 0 "kid" == "TESTKEY123" && part 1 "iss" == "issuer-uuid" do
      bad := bad.push (line r)
  check s!"{name}: {rs.size} requests, each with a token that verifies with the key" (!rs.isEmpty && bad.isEmpty)
    s!"{bad}"

def testflightChecks (dir : System.FilePath) (port : Nat) (c : Asc.Config) (notes : String) : IO Unit := do
  reset port [("builds", Json.arr #[Json.mkObj [("id", "BUILD1"), ("version", "42"), ("preReleaseVersion", "1.2.3"),
      ("uploadedDate", "2026-11-04T00:00:00Z"), ("processing", Json.arr #["PROCESSING", "PROCESSING", "VALID"])]]),
    ("faults", faults [("POST", "/v1/betaBuildLocalizations", 429, 1), ("POST", "/v1/betaAppReviewSubmissions", 409, 1)])]
  let rs ← passes port c "register-bundle-id: registers" "register-bundle-id" ["registered bundle id com.example.probe"]
  let w := writes rs
  check "register-bundle-id: one POST /bundleIds with the identifier, name and platform"
    (w.map line == #["POST /v1/bundleIds"] && body w[0]! ["data", "attributes", "identifier"] == "com.example.probe" &&
      body w[0]! ["data", "attributes", "name"] == "Probe" && body w[0]! ["data", "attributes", "platform"] == "IOS")
    s!"{w.map (·.compress)}"
  let rs ← passes port c "register-bundle-id: again, finds it" "register-bundle-id" ["is registered"]
  check "register-bundle-id: again, no write" (writes rs).isEmpty
  let rs ← passes port c "create-app: creates the record" "create-app" ["created the app record for com.example.probe"]
  let w := writes rs
  check "create-app: one POST /apps naming the registered bundle id, the SKU and en-US"
    (w.map line == #["POST /v1/apps"] && body w[0]! ["data", "relationships", "bundleId", "data", "id"] == "BUNDLE1" &&
      body w[0]! ["data", "attributes", "sku"] == "PROBE1" && body w[0]! ["data", "attributes", "primaryLocale"] == "en-US")
    s!"{w.map (·.compress)}"
  let rs ← passes port c "create-app: again, finds it" "create-app" ["app record exists"]
  check "create-app: again, no write" (writes rs).isEmpty
  let rs ← passes port c "wait-processing: waits for a build still processing" "wait-processing"
    ["build BUILD1: PROCESSING", "build BUILD1: VALID"]
  check "wait-processing: finds the build by version and number, reads it until VALID, no write"
    ((writes rs).isEmpty && (rs.map line).contains
      "GET /v1/builds?filter[app]=APP2&filter[version]=42&filter[preReleaseVersion.version]=1.2.3&limit=2" &&
      (rs.filter (line · == "GET /v1/builds/BUILD1")).size == 3) s!"{rs.map line}"
  let rs ← passes port c "notes: past a 429" "notes" ["en-US What to Test set for build BUILD1", "attempt 1/8"]
  let w := writes rs
  check "notes: POST /betaBuildLocalizations twice (429, then created) with the text, en-US, the build"
    (w.map line == #["POST /v1/betaBuildLocalizations", "POST /v1/betaBuildLocalizations"] &&
      w.all fun r => body r ["data", "attributes", "whatsNew"] == notes && body r ["data", "attributes", "locale"] == "en-US" &&
        body r ["data", "relationships", "build", "data", "id"] == "BUILD1") s!"{w.map (·.compress)}"
  let rs ← passes port c "notes: again, updates the localization" "notes" ["en-US What to Test set"]
  check "notes: again, one PATCH of the localization"
    ((writes rs).map line == #["PATCH /v1/betaBuildLocalizations/LOC3"]) s!"{(writes rs).map line}"
  discard <| passes port c "check-notes" "check-notes" [s!"notes: {notes.length} of 4000 characters"]
  let rs ← refuses port c "status: before external, not with testers yet" "status" "not with external testers yet"
  check "status: reads only" (writes rs).isEmpty s!"{(writes rs).map line}"
  let rs ← passes port c "internal: testable" "internal" ["internal: build BUILD1 is READY_FOR_BETA_TESTING"]
  check "internal: reads only" (writes rs).isEmpty
  let rs ← passes port c "external: past a 409" "external"
    ["added build BUILD1 to the public link", "attempt 1/12", "review state is WAITING_FOR_REVIEW"]
  let w := writes rs
  check "external: the build into the public link's group, then the review submission twice (409, then created)"
    (w.map line == #["POST /v1/betaGroups/GROUP1/relationships/builds", "POST /v1/betaAppReviewSubmissions",
        "POST /v1/betaAppReviewSubmissions"] &&
      strOf (at? (arrOf (w[0]!.getObjValD "body" |>.getObjValD "data"))[0]! ["id"]) == "BUILD1" &&
      body w[2]! ["data", "relationships", "build", "data", "id"] == "BUILD1") s!"{w.map (·.compress)}"
  let rs ← passes port c "external: again, finds it done" "external"
    ["already belongs to the public link", "review state is WAITING_FOR_REVIEW"]
  check "external: again, no write" (writes rs).isEmpty s!"{(writes rs).map line}"
  let rs ← passes port c "status: with external testers" "status"
    ["build=BUILD1 processing=VALID internal=READY_FOR_BETA_TESTING", "review=WAITING_FOR_REVIEW public_link=LINK1 grouped=yes"]
  check "status: reads only" (writes rs).isEmpty
  let rs ← passes port c "check: the app and its newest build" "check"
    ["app APP2 (com.example.probe); newest build BUILD1, build number 42, VALID, uploaded 2026-11-04T00:00:00Z"]
  check "check: reads only" (writes rs).isEmpty
  tokenChecks dir "testflight" (← requests port)

def appStoreChecks (dir : System.FilePath) (port : Nat) (c : Asc.Config) (text : String) : IO Unit := do
  reset port [("apps", app), ("bundleIds", bundleIds)]
  let rs ← refuses port c "appstore-status: no build, no What's New" "appstore-status" "appstore: missing build, whatsNew"
  check "appstore-status: reads only" (writes rs).isEmpty s!"{(writes rs).map line}"
  let rs ← refuses port { c with confirmSubmit := false } "appstore-submit: refused unconfirmed" "appstore-submit"
    "refusing to submit without APPSTORE_CONFIRM_SUBMIT=yes"
  check "appstore-submit: unconfirmed, no request" rs.isEmpty
  let rs ← refuses port c "appstore-submit: no build attached" "appstore-submit" "version VER1 has no build attached"
  check "appstore-submit: no build, no write" (writes rs).isEmpty
  let rs ← passes port c "appstore-attach: attaches" "appstore-attach" ["attached build BUILD1 to version VER1"]
  let w := writes rs
  check "appstore-attach: one PATCH of the version with the build and its string"
    (w.map line == #["PATCH /v1/appStoreVersions/VER1"] &&
      body w[0]! ["data", "relationships", "build", "data", "id"] == "BUILD1" &&
      body w[0]! ["data", "attributes", "versionString"] == "1.2.3") s!"{w.map (·.compress)}"
  let rs ← passes port c "appstore-attach: again, finds it" "appstore-attach" ["build BUILD1 is already attached to version VER1"]
  check "appstore-attach: again, no write" (writes rs).isEmpty
  let rs ← passes port c "appstore-notes" "appstore-notes" ["en-US What's New set for version VER1"]
  let w := writes rs
  check "appstore-notes: one PATCH of the en-US localization with the text"
    (w.map line == #["PATCH /v1/appStoreVersionLocalizations/VLOC1"] &&
      body w[0]! ["data", "attributes", "whatsNew"] == text) s!"{w.map (·.compress)}"
  let rs ← passes port c "appstore-status: complete" "appstore-status"
    ["version=VER1 string=1.2.3 state=PREPARE_FOR_SUBMISSION release=MANUAL build=BUILD1 (build 42, VALID)",
     "locale=en-US whatsNew=yes", "screenshotSets=APP_IPHONE_67", "ageRating=FOUR_PLUS primaryCategory=UTILITIES",
     "name=Probe", "openReviewSubmissions=0", "appstore: metadata complete"]
  check "appstore-status: reads only" (writes rs).isEmpty
  let rs ← passes port c "appstore-submit: submits" "appstore-submit" ["created submission RS1", "submission RS1 is WAITING_FOR_REVIEW"]
  let w := writes rs
  check "appstore-submit: a submission, the version as its item, then submitted"
    (w.map line == #["POST /v1/reviewSubmissions", "POST /v1/reviewSubmissionItems", "PATCH /v1/reviewSubmissions/RS1"] &&
      body w[0]! ["data", "relationships", "app", "data", "id"] == "APP1" &&
      body w[1]! ["data", "relationships", "appStoreVersion", "data", "id"] == "VER1" &&
      at? (w[2]!.getObjValD "body") ["data", "attributes", "submitted"] == true) s!"{w.map (·.compress)}"
  let rs ← passes port c "appstore-submit: again, already waiting" "appstore-submit" ["submission RS1 is already WAITING_FOR_REVIEW"]
  check "appstore-submit: again, no write" (writes rs).isEmpty
  tokenChecks dir "appstore" (← requests port)

def ascFailureChecks (port : Nat) (c : Asc.Config) : IO Unit := do
  reset port [("apps", app), ("bundleIds", bundleIds), ("echoNotes", false)]
  let rs ← refuses port c "notes: other text back, after 8 tries" "notes" "App Store Connect did not return the text sent"
  check "notes: other text back, 8 writes" ((writes rs).size == 8) s!"{(writes rs).map line}"
  reset port [("apps", app), ("bundleIds", bundleIds)]
  let rs ← refuses port { c with build := some "43", waitAttempts := 2 } "wait-processing: a build that never appears"
    "wait-processing" "uploaded version 1.2.3 build 43 never appeared"
  check "wait-processing: looked twice" ((rs.filter fun r => (line r).startsWith "GET /v1/builds?").size == 2) s!"{rs.map line}"
  reset port [("apps", app), ("bundleIds", bundleIds), ("builds", Json.arr #[Json.mkObj [("id", "BUILD1"),
    ("version", "42"), ("preReleaseVersion", "1.2.3"), ("uploadedDate", "2026-11-04T00:00:00Z"),
    ("processing", Json.arr #["PROCESSING", "INVALID"])]])]
  discard <| refuses port c "wait-processing: an invalid build" "wait-processing" "build BUILD1 is INVALID"
  reset port []
  let rs ← refuses port c "check: no app record, after 5 tries" "check" "no app record"
  check "check: no app record, 5 lookups" (rs.size == 5) s!"{rs.map line}"
  reset port [("apps", app), ("bundleIds", bundleIds), ("faults", faults [("PATCH", "/v1/appStoreVersions/", 409, 99)])]
  discard <| refuses port c "appstore-attach: a 409 is App Store Connect's answer in the error" "appstore-attach"
    "PATCH /appStoreVersions/VER1: curl exit 22"
  let (_, err, _) ← runStep port c "appstore-attach"
  check "appstore-attach: the error carries Apple's detail" ((err.getD "").contains "the fake refuses PATCH /v1/appStoreVersions/VER1 with 409")
    (err.getD "")
  reset port [("apps", app), ("bundleIds", bundleIds), ("betaReviews", Json.mkObj [("BUILD1", "REJECTED")])]
  discard <| refuses port c "external: a rejected build" "external" "build BUILD1 was rejected by beta review"
  discard <| refuses port { c with publicLinkId := some "OTHER" } "external: another public link" "external"
    "expected exactly one public beta group for link OTHER; found 0"
  discard <| refuses port c "an unknown step" "launch" "unknown step launch"

/-- `leannative-release testflight check`, configured by the environment as a release workflow does. -/
def binaryChecks (dir : System.FilePath) (port : Nat) : IO Unit := do
  reset port [("apps", app), ("bundleIds", bundleIds)]
  let tool := (← IO.appDir) / "leannative-release"
  let env : Array (String × Option String) := #[("ASC_KEY_ID", "TESTKEY123"), ("ASC_ISSUER_ID", "issuer-uuid"),
    ("ASC_KEY_PATH", (dir / "AuthKey_TEST.p8").toString), ("APP_BUNDLE_ID", "com.example.probe"),
    ("ASC_API", s!"http://127.0.0.1:{port}/v1"), ("TESTFLIGHT_BUILD_ID", none), ("TESTFLIGHT_MARKETING_VERSION", none),
    ("TESTFLIGHT_BUILD_NUMBER", none), ("TESTFLIGHT_BUILD_WAIT_ATTEMPTS", none)]
  let out ← run tool.toString #["testflight", "check"] (check := false) (env := env)
  check "leannative-release testflight check: against ASC_API"
    (out.exitCode == 0 && out.stdout.contains "App Store Connect: app APP1 (com.example.probe); newest build BUILD1")
    (trim (out.stdout ++ out.stderr))
  let out ← run tool.toString #["testflight", "check"] (check := false)
    (env := env.push ("TESTFLIGHT_BUILD_WAIT_ATTEMPTS", "soon"))
  check "leannative-release testflight: a wait that is not a number"
    (out.exitCode == 1 && out.stderr.contains "TESTFLIGHT_BUILD_WAIT_ATTEMPTS is not a number: soon") (trim out.stderr)

/-- The fake's app, jwtChecks's key, no pauses. -/
def fakeConfig (dir : System.FilePath) (port : Nat) (notes appStoreNotes : System.FilePath) : Asc.Config :=
  { keyId := "TESTKEY123", issuer := "issuer-uuid", keyPath := (dir / "AuthKey_TEST.p8").toString,
    bundleId := "com.example.probe", api := s!"http://127.0.0.1:{port}/v1", version := some "1.2.3",
    build := some "42", notesFile := some notes.toString, publicLinkId := some "LINK1", waitSeconds := 0,
    retrySeconds := 0, processingSeconds := 0, submitSeconds := 0, appStoreVersionString := some "1.2.3",
    appStoreNotesFile := some appStoreNotes.toString, confirmSubmit := true, appName := some "Probe",
    sku := some "PROBE1" }

def ascChecks (dir : System.FilePath) (python script : String) : IO Unit := do
  let notes := dir / "testflight.txt"
  IO.FS.writeFile notes "What to Test: everything.\n"
  let appStoreNotes := dir / "appstore.txt"
  IO.FS.writeFile appStoreNotes "Fixes.\n"
  let (child, port) ← startFake python script
  try
    let c := fakeConfig dir port notes appStoreNotes
    testflightChecks dir port c "What to Test: everything."
    appStoreChecks dir port c "Fixes."
    ascFailureChecks port c
    binaryChecks dir port
  finally
    child.kill
    discard <| child.wait

def main (args : List String) : IO UInt32 := do
  let python := args[0]?.getD "python3"
  let script := args[1]?.getD "../scripts/fake_asc.py"
  let dir ← IO.FS.createTempDir
  try
    policyChecks dir
    jwtChecks dir
    ascChecks dir python script
    bundleChecks dir
  catch e => check "no step throws" false (toString e)
  IO.FS.removeDirAll dir
  let (passed, failed) ← checks.get
  IO.println s!"release-test: {passed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
