import LeanNativeShell.Manifest

/-! # The app manifest: what generation refuses, and what it writes

Each capability family that needs an Info.plist key or an entitlement (`LeanNativeShell.requirements`) is refused
without it, with the key named, and accepted with it, whether it comes from the manifest's own field or
from the `info` / `entitlements` escape hatches; a family that needs nothing is accepted bare. Then the
spec: the shell's wiring, the derived background modes, the Mac variants, and the escape hatches over the
generated values. -/

open Lean LeanNativeShell

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) (why : String := "") : IO Unit := do
  if ok then IO.println s!"ok   {name}"
  else IO.println s!"FAIL {name}{if why.isEmpty then "" else s!": {why}"}"; failures.modify (· + 1)

def base : Manifest := { name := "App", displayName := "App", bundleId := "com.example.app" }

def paths : Paths := { native := "../fw/native", leanInclude := "/lean/include" }

/-- Refused, with every problem naming `key`. -/
def refused (name : String) (m : Manifest) (key : String) : IO Unit :=
  match m.generate paths with
  | .ok _ => check name false s!"generated, but {key} is missing"
  | .error ps => check name (ps.any (·.contains key)) s!"no problem names {key}: {ps}"

def accepted (name : String) (m : Manifest) : IO Unit :=
  match m.generate paths with
  | .ok _ => check name true
  | .error ps => check name false s!"{ps}"

def at? (j : Json) (keys : List String) : Option Json :=
  keys.foldlM (fun j k => (j.getObjVal? k).toOption) j

def is (j : Json) (keys : List String) (v : Json) : Bool := at? j keys == some v

def main : IO UInt32 := do
  -- auth
  refused "auth without a Face ID text" { base with uses := ["auth"] } "NSFaceIDUsageDescription"
  accepted "auth with one" { base with uses := ["auth"], usage := [("NSFaceIDUsageDescription", "Pay.")] }
  refused "auth with a blank one" { base with uses := ["auth"], usage := [("NSFaceIDUsageDescription", "  ")] }
    "NSFaceIDUsageDescription"
  -- ble
  refused "ble.* without a Bluetooth text" { base with uses := ["ble.*"] } "NSBluetoothAlwaysUsageDescription"
  refused "ble.connect alone without one" { base with uses := ["ble.connect"] } "NSBluetoothAlwaysUsageDescription"
  accepted "ble.* with one, through info" { base with
    uses := ["ble.*"], info := [("NSBluetoothAlwaysUsageDescription", "Talks to your signer.")] }
  -- bgtask
  refused "bgtask.* without identifiers" { base with uses := ["bgtask.*"] } "BGTaskSchedulerPermittedIdentifiers"
  refused "bgtask.* without background modes" { base with
    uses := ["bgtask.*"], info := [("BGTaskSchedulerPermittedIdentifiers", toJson ["com.example.app.refresh"])] } "UIBackgroundModes"
  refused "bgtask.* with its modes taken away" { base with
    uses := ["bgtask.*"], backgroundTasks := [("com.example.app.refresh", .refresh)], info := [("UIBackgroundModes", toJson ([] : List String))] }
    "UIBackgroundModes"
  accepted "bgtask.* with tasks" { base with uses := ["bgtask.*"], backgroundTasks := [("com.example.app.refresh", .refresh)] }
  -- cloudkit
  refused "cloudkit.* without a container" { base with uses := ["cloudkit.*"] } "com.apple.developer.icloud-container-identifiers"
  refused "cloudkit.* without the CloudKit service" { base with
    uses := ["cloudkit.*"], entitlements := [("com.apple.developer.icloud-container-identifiers", toJson ["iCloud.com.example.app"])] }
    "com.apple.developer.icloud-services"
  accepted "cloudkit.* with a container" { base with uses := ["cloudkit.*"], iCloudContainers := ["iCloud.com.example.app"] }
  -- families that need nothing, and names the shell does not have
  accepted "keychain, http, clipboard, open: nothing needed" { base with
    uses := ["keychain.*", "http.get", "clipboard.*", "open", "documents", "paths"] }
  refused "an unknown capability" { base with uses := ["camera.scan"] } "camera.scan"
  refused "an unknown family" { base with uses := ["nfc.*"] } "nfc.*"
  refused "a name with a space" { base with name := "My App" } "name"
  refused "every problem at once" { base with uses := ["auth", "ble.*"] } "NSBluetoothAlwaysUsageDescription"

  -- what the app's code calls (#24): Lean's C names a capability as a string literal, in quotes
  let c (file text : String) : String × String := (file, text)
  let demo := [c "App_Probes.c" "x = lean_mk_string_unchecked(\"ble.connect\", 11, 11);",
               c "App_Main.c" "static const char l_k[] = \"keychain.get\"; y = \"authenticationFailure\";",
               c "App_Cloud.c" "z = lean_mk_string_unchecked(\"cloudkit.account\", 16, 16);"]
  let calls := calledIn demo
  check "calls: each name the C quotes, with its file" (calls == [("keychain.get", "App_Main.c"),
    ("ble.connect", "App_Probes.c"), ("cloudkit.account", "App_Cloud.c")]) s!"{calls}"
  check "calls: a longer literal is not a call" (!(calls.any (·.1 == "auth")))
  check "calls: a name outside quotes is not a call" ((calledIn [c "A.c" "// ble.close keychain.get"]).isEmpty)
  let ok : Manifest := { base with uses := ["keychain.*", "ble.connect"], unlisted := ["cloudkit.*"] }
  check "calls: covered by a family, a name and unlisted" (ok.callProblems calls).isEmpty s!"{ok.callProblems calls}"
  let missing := { ok with unlisted := [] }.callProblems calls
  check "calls: a family the app calls but does not list is refused, naming the capability and file"
    (missing.length == 1 && missing.any (fun p => p.contains "cloudkit.account" && p.contains "App_Cloud.c"))
    s!"{missing}"
  let twoBle := calledIn [c "A.c" "\"ble.connect\" \"ble.close\""]
  check "calls: one problem per family" (({ base with uses := [] }.callProblems twoBle).length == 1)
  check "calls: a name does not cover its family" (({ base with uses := ["ble.connect"] }.callProblems twoBle).any (·.contains "ble.close"))
  check "unused: an entry no call covers" ({ ok with uses := ok.uses ++ ["clipboard.*", "auth"] }.unusedUses calls == ["clipboard.*", "auth"])
  check "unused: none when every entry is called" (ok.unusedUses calls).isEmpty
  refused "an unknown unlisted capability" { base with unlisted := ["nfc.*"] } "nfc.*"

  -- the spec
  let m : Manifest := { base with
    mac := .catalyst, uses := ["bgtask.*"], team := some "TEAM123", version := .settings "1.2.3" "45",
    orientations := some ([.portrait], [.portrait, .landscapeLeft]), icon := some "Assets.xcassets",
    resources := ["../docs/a.html"], uiTests := some {},
    backgroundTasks := [("r1", .refresh), ("p1", .processing), ("r2", .refresh)],
    iCloudContainers := ["iCloud.com.example.app"], keychainGroups := ["$(AppIdentifierPrefix)com.example.app"],
    info := [("ITSAppUsesNonExemptEncryption", false), ("CFBundleDisplayName", "Shown")],
    settings := [("GCC_OPTIMIZATION_LEVEL", "s"), ("OTHER_CFLAGS", toJson ["-DAPP"])],
    testSettings := [("TEST_FLAG", "YES")],
    spec := Json.mkObj [("options", Json.mkObj [("createIntermediateGroups", true)])] }
  let p := m.project paths
  let app := ["targets", "App"]
  let set := app ++ ["settings", "base"]
  let info := app ++ ["info", "properties"]
  check "the shell's sources" (at? p (app ++ ["sources"]) == some (Json.arr #[
    Json.mkObj [("path", "build/native-shell"), ("name", "LeanNativeShell")],
    Json.mkObj [("path", "../fw/native/c"), ("name", "LeanNativeShim")],
    Json.mkObj [("path", "../fw/native/driver"), ("name", "LeanNativeDriver")],
    Json.mkObj [("path", "build/lean-c"), ("name", "LeanC"), ("compilerFlags", toJson ["-w"])],
    Json.mkObj [("path", "../docs/a.html"), ("buildPhase", "resources")],
    Json.mkObj [("path", "Assets.xcassets")]]))
  check "the scene delegate" (is p (info ++ ["UIApplicationSceneManifest", "UISceneConfigurations"])
    (Json.mkObj [("UIWindowSceneSessionRoleApplication", Json.arr #[Json.mkObj [
      ("UISceneConfigurationName", "Default"), ("UISceneDelegateClassName", "LNSceneDelegate")]])]))
  check "ARC and the script sandbox" (is p ["settings", "base", "CLANG_ENABLE_OBJC_ARC"] "YES"
    && is p ["settings", "base", "ENABLE_USER_SCRIPT_SANDBOXING"] "YES")
  check "Lean's headers and the shim's" (is p (set ++ ["HEADER_SEARCH_PATHS"]) (toJson ["/lean/include", "$(PROJECT_DIR)/../fw/native/c"]))
  check "background modes from the kinds, once each" (is p (info ++ ["UIBackgroundModes"]) (toJson ["fetch", "processing"]))
  check "the identifiers in order" (is p (info ++ ["BGTaskSchedulerPermittedIdentifiers"]) (toJson ["r1", "p1", "r2"]))
  check "versions from settings" (is p (info ++ ["CFBundleShortVersionString"]) "$(MARKETING_VERSION)"
    && is p (set ++ ["MARKETING_VERSION"]) "1.2.3" && is p (set ++ ["CURRENT_PROJECT_VERSION"]) "45")
  check "orientations" (is p (info ++ ["UISupportedInterfaceOrientations~ipad"])
    (toJson ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft"]))
  check "team, signed automatically" (is p (set ++ ["DEVELOPMENT_TEAM"]) "TEAM123" && is p (set ++ ["CODE_SIGN_STYLE"]) "Automatic")
  check "the icon" (is p (set ++ ["ASSETCATALOG_COMPILER_APPICON_NAME"]) "AppIcon")
  check "Mac Catalyst, both targets" (is p (set ++ ["SUPPORTS_MACCATALYST"]) "YES"
    && is p ["targets", "AppUITests", "settings", "base", "SUPPORTS_MACCATALYST"] "YES")
  check "entitlements: iCloud and keychain groups" (is p (app ++ ["entitlements", "properties", "com.apple.developer.icloud-services"]) (toJson ["CloudKit"])
    && is p (app ++ ["entitlements", "properties", "keychain-access-groups"]) (toJson ["$(AppIdentifierPrefix)com.example.app"])
    && is p (set ++ ["CODE_SIGN_ENTITLEMENTS"]) "build/App.entitlements")
  check "info over the generated keys" (is p (info ++ ["CFBundleDisplayName"]) "Shown"
    && is p (info ++ ["ITSAppUsesNonExemptEncryption"]) false)
  check "settings over the generated ones" (is p (set ++ ["GCC_OPTIMIZATION_LEVEL"]) "s" && is p (set ++ ["OTHER_CFLAGS"]) (toJson ["-DAPP"]))
  check "test settings" (is p ["targets", "AppUITests", "settings", "base", "TEST_FLAG"] "YES"
    && is p ["targets", "AppUITests", "settings", "base", "PRODUCT_BUNDLE_IDENTIFIER"] "com.example.app.uitests")
  check "the test kit in the test target only" ((at? p ["targets", "AppUITests", "sources"]).any (·.compress.contains "LeanNativeTestKit")
    && !((at? p (app ++ ["sources"])).any (·.compress.contains "testkit")))
  check "spec merged last, the rest kept" (is p ["options", "createIntermediateGroups"] true && is p ["options", "xcodeVersion"] "27.1")
  check "the scheme tests the UI tests" (is p ["schemes", "App", "test", "targets"] (toJson ["AppUITests"]))
  let plain := base.project paths
  check "no Mac: not Designed for iPad either" (is plain ["targets", "App", "settings", "base", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] "NO"
    && at? plain ["targets", "App", "settings", "base", "SUPPORTS_MACCATALYST"] == none)
  check "Designed for iPad" (is ({ base with mac := .designedForiPad }.project paths)
    ["targets", "App", "settings", "base", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] "YES")
  check "no entitlements, no entitlements file" (at? plain ["targets", "App", "entitlements"] == none
    && at? plain ["targets", "App", "settings", "base", "CODE_SIGN_ENTITLEMENTS"] == none)
  check "fixed versions in Info.plist" (is plain ["targets", "App", "info", "properties", "CFBundleVersion"] "1")
  check "no UI tests, no test target" (at? plain ["targets", "AppUITests"] == none
    && at? plain ["schemes", "App", "test"] == none)
  let n ← failures.get
  IO.println (if n == 0 then "manifest: all passed" else s!"manifest: {n} failed")
  return if n == 0 then 0 else 1
