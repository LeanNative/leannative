import LeanNativeRelease.Run

/-! # The built app, before it goes to App Store Connect

`verifyApp` checks an archived or exported `.app`: the identity the release asked for (bundle identifier,
team, version and build number), export compliance declared in Info.plist, the icon from the asset catalog,
a valid signature with the team's application identifier, the iCloud container when the app has one
(production iCloud for distribution), debugging off for distribution, arm64 only, and no Swift.
`verifyIpa` opens the exported package, checks its one app for distribution and records the package's
SHA-256 beside it (`<ipa>.verified.sha256`), which the upload step checks first, so what is uploaded is what
was verified. -/

namespace LeanNativeRelease
open Lean

structure Identity where
  bundleId : String
  teamId : String
  version : String
  build : String
  /-- `iCloud.…`, for an app with iCloud; none: the app has no iCloud entitlement to check -/
  icloudContainer : Option String := none

/-- APP_BUNDLE_ID, APP_TEAM_ID, TESTFLIGHT_MARKETING_VERSION, TESTFLIGHT_BUILD_NUMBER, APP_ICLOUD_CONTAINER. -/
def Identity.fromEnv : IO Identity := do
  return { bundleId := ← need "APP_BUNDLE_ID", teamId := ← need "APP_TEAM_ID",
           version := ← need "TESTFLIGHT_MARKETING_VERSION", build := ← need "TESTFLIGHT_BUILD_NUMBER",
           icloudContainer := ← env? "APP_ICLOUD_CONTAINER" }

private def check (ok : Bool) (message : String) : IO Unit := unless ok do fail message

/-- The entitlements the app is signed with. -/
def entitlements (app : System.FilePath) : IO Json := do
  let out ← run "codesign" #["-d", "--entitlements", ":-", app.toString]
  let file ← tempFile out.stdout.toUTF8
  try plistJson file finally IO.FS.removeFile file

def verifyApp (app : System.FilePath) (id : Identity) (distribution : Bool) : IO Unit := do
  let info ← plistJson (app / "Info.plist")
  let infoStr (k : String) := strOf (info.getObjValD k)
  check (infoStr "CFBundleShortVersionString" == id.version)
    s!"app version {infoStr "CFBundleShortVersionString"}, not {id.version}"
  check (infoStr "CFBundleVersion" == id.build) s!"app build number {infoStr "CFBundleVersion"}, not {id.build}"
  check (infoStr "CFBundleIdentifier" == id.bundleId) s!"app bundle {infoStr "CFBundleIdentifier"}, not {id.bundleId}"
  check (boolOf? (info.getObjValD "ITSAppUsesNonExemptEncryption")).isSome
    "export compliance must be declared (ITSAppUsesNonExemptEncryption in Info.plist)"
  check (strOf (at? info ["CFBundleIcons", "CFBundlePrimaryIcon", "CFBundleIconName"]) == "AppIcon")
    "the app icon must come from the asset catalog (CFBundleIconName AppIcon)"
  discard <| run "codesign" #["--verify", "--deep", "--strict", app.toString]
  let ent ← entitlements app
  let entStr (k : String) := strOf (ent.getObjValD k)
  check (entStr "application-identifier" == s!"{id.teamId}.{id.bundleId}")
    s!"signed as {entStr "application-identifier"}, not {id.teamId}.{id.bundleId}"
  check (entStr "com.apple.developer.team-identifier" == id.teamId)
    s!"signing team {entStr "com.apple.developer.team-identifier"}, not {id.teamId}"
  let debuggable := boolOf? (ent.getObjValD "get-task-allow")
  let release := distribution || debuggable != some true
  if let some container := id.icloudContainer then
    check ((arrOf (ent.getObjValD "com.apple.developer.icloud-container-identifiers")).map strOf == #[container])
      s!"the iCloud container is not {container}"
    check ((arrOf (ent.getObjValD "com.apple.developer.icloud-services")).any (strOf · == "CloudKit"))
      "the iCloud services do not include CloudKit"
    let environment := ent.getObjValD "com.apple.developer.icloud-container-environment"
    if release then
      check (strOf environment == "Production") "distribution requires production iCloud"
    else
      -- Xcode adds the selected environment when it exports a development archive
      check (environment == .null || ["Development", "Production"].contains (strOf environment))
        s!"unexpected archive iCloud environment {environment.compress}"
  if release then check (debuggable == some false) "distribution must disable debugging (get-task-allow)"
  let binary := app / infoStr "CFBundleExecutable"
  let archs := ((← run "lipo" #["-archs", binary.toString]).stdout.splitOn " ").map trim |>.filter (· != "")
  check (archs == ["arm64"]) s!"the app must contain only the arm64 executable, not {archs}"
  check (!((← run "otool" #["-L", binary.toString]).stdout.toLower.contains "swift")) "the app links a Swift library"
  let frameworks := app / "Frameworks"
  if ← frameworks.pathExists then
    for entry in ← frameworks.readDir do
      check (!entry.fileName.toLower.contains "swift") s!"the app bundles a Swift library ({entry.fileName})"
  say (if distribution then "Distribution identity, signature, iCloud, arm64 and no Swift verified."
       else "Archive identity, signature, iCloud, arm64 and no Swift verified; the export is checked separately.")

def verifyIpa (ipa : System.FilePath) (id : Identity) : IO Unit := do
  let work ← IO.FS.createTempDir
  try
    discard <| run "ditto" #["-x", "-k", ipa.toString, work.toString]
    let payload := work / "Payload"
    let apps := (← payload.readDir).filter (·.fileName.endsWith ".app")
    let #[app] := apps | fail s!"expected exactly one app in {ipa}, found {apps.size}"
    verifyApp app.path id true
  finally
    IO.FS.removeDirAll work
  let sum ← run "shasum" #["-a", "256", ipa.toString]
  IO.FS.writeFile (ipa.toString ++ ".verified.sha256") sum.stdout
  say s!"recorded {trim sum.stdout}"

end LeanNativeRelease
