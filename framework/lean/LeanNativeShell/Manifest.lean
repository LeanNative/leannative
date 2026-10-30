import Lean.Data.Json
import LeanNativeShell.Capabilities

/-! # LeanNativeShell.Manifest: an app's Xcode project, from Lean

An app describes itself once, as a `Manifest`, and LeanNative writes the XcodeGen spec of its Xcode project
from it; `framework/native/ci/build-ios` then runs XcodeGen on that spec. The app's `ios/` directory keeps
only what cannot be generated: its icon and its UI tests (Objective-C XCTest).

What every LeanNative app has comes from here, never from the app: the printed shell (`build/native-shell`),
the C shim and Lean's C as sources, the shell's scene delegate (`LNSceneDelegate`), ARC and the script
sandbox, Lean's headers and retargeted libraries, `-O3`, ad-hoc signing in the simulator. What the app's
capabilities need comes from the manifest, and is checked against the capabilities it says it uses
(`uses`): generation refuses a manifest that uses `ble.*` with no Bluetooth usage text, say, instead of
the app crashing on its first Bluetooth call (`requirements`). And `uses` is checked against the app's
code: build-ios hands generation the C that Lean wrote for the app, and a capability named there whose
family `uses` does not list is refused too (`Manifest.callProblems`).

The app keeps every escape hatch: `info`, `entitlements`, `settings` and `testSettings` set any Info.plist
key, entitlement or build setting (over the generated ones), and `spec` is merged into the whole XcodeGen
spec last. An app package runs it from an executable of its own (`[[lean_exe]] name = "ios-project"`, whose
`main` is `Manifest.main`); framework/native/README.md has the details. -/

namespace LeanNativeShell
open Lean

/-- How the app's version reaches Info.plist. -/
inductive Version where
  /-- `CFBundleShortVersionString` and `CFBundleVersion`, written into Info.plist as they are. -/
  | fixed (short build : String)
  /-- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` build settings, which Info.plist reads: a release
  sets them from its tag with xcodebuild arguments. -/
  | settings (marketing current : String)

/-- Where the iPad app runs on a Mac. -/
inductive Mac where
  /-- not on a Mac -/
  | none
  /-- the iPad app on Apple silicon Macs ("Designed for iPad"), with no Mac Catalyst build -/
  | designedForiPad
  /-- a Mac Catalyst build too, with the same bundle id as on iOS (one app, one iCloud container), ad-hoc
  signed to run locally; the UI tests build for it as well -/
  | catalyst

inductive Orientation where
  | portrait | portraitUpsideDown | landscapeLeft | landscapeRight

def Orientation.key : Orientation → String
  | .portrait => "UIInterfaceOrientationPortrait"
  | .portraitUpsideDown => "UIInterfaceOrientationPortraitUpsideDown"
  | .landscapeLeft => "UIInterfaceOrientationLandscapeLeft"
  | .landscapeRight => "UIInterfaceOrientationLandscapeRight"

/-- A background task's kind (`bgtask.schedule`'s `kind`), which decides its `UIBackgroundModes` entry. -/
inductive TaskKind where
  | refresh | processing

def TaskKind.mode : TaskKind → String
  | .refresh => "fetch"
  | .processing => "processing"

/-- The app's UI-test target (Objective-C XCUITest), which alone compiles the framework's test kit. -/
structure UITests where
  /-- its sources, relative to the app's `ios/` directory -/
  sources : List String := ["UITests"]
  /-- default: the app's bundle id + `.uitests` -/
  bundleId : Option String := none

structure Manifest where
  /-- the Xcode project, target, scheme and product name -/
  name : String
  /-- `CFBundleDisplayName`, the name under the icon -/
  displayName : String
  bundleId : String
  /-- `DEVELOPMENT_TEAM`, signed automatically; none: ad-hoc in the simulator and on a Mac, unsigned for a
  device unless xcodebuild arguments sign it -/
  team : Option String := none
  version : Version := .fixed "0.1.0" "1"
  deploymentTarget : String := "17.0"
  xcodeVersion : String := "27.1"
  mac : Mac := .none
  /-- `UISupportedInterfaceOrientations` on iPhone, then `~ipad`; none: the system's default -/
  orientations : Option (List Orientation × List Orientation) := none
  /-- an asset catalog holding `AppIcon`, relative to `ios/` -/
  icon : Option String := none
  /-- files bundled as resources, relative to `ios/` -/
  resources : List String := []
  /-- the shell capabilities the app calls: names (`auth`) or families (`ble.*`) of `LeanNativeShell.capabilities` -/
  uses : List String := []
  /-- capability families the app calls without listing them in `uses`, on purpose: their requirements are
  not checked (native-demo calls `cloudkit.*` with no iCloud container, to show the shell's
  `missingEntitlement` answer) -/
  unlisted : List String := []
  /-- Info.plist usage texts, by key (`NSFaceIDUsageDescription`, …): what the system shows when it asks -/
  usage : List (String × String) := []
  /-- the identifiers the shell registers launch handlers for (`BGTaskSchedulerPermittedIdentifiers`), each
  with its kind; `UIBackgroundModes` follows from the kinds -/
  backgroundTasks : List (String × TaskKind) := []
  /-- iCloud containers for CloudKit (`com.apple.developer.icloud-container-identifiers`) -/
  iCloudContainers : List String := []
  /-- `keychain-access-groups`; none: the app's default group -/
  keychainGroups : List String := []
  uiTests : Option UITests := none
  /-- any other Info.plist keys, over the generated ones -/
  info : List (String × Json) := []
  /-- any other entitlements, over the generated ones -/
  entitlements : List (String × Json) := []
  /-- any other build settings of the app target, over the generated ones -/
  settings : List (String × Json) := []
  /-- any other build settings of the UI-test target, over the generated ones -/
  testSettings : List (String × Json) := []
  /-- merged into the whole XcodeGen spec last (objects key by key, anything else replaced) -/
  spec : Json := Json.mkObj []

/-- Where the generated spec points, all relative to the project root (the app's `ios/` directory) except
Lean's headers: build-ios passes them. -/
structure Paths where
  /-- framework/native -/
  native : String
  /-- the build directory: the printed shell, Lean's C, the retargeted libraries, Info.plist -/
  build : String := "build"
  /-- Lean's `include` directory -/
  leanInclude : String

/-- Objects merged key by key; anything else, the second wins. -/
partial def deepMerge (a b : Json) : Json :=
  match a.getObj?, b.getObj? with
  | .ok oa, .ok ob => ob.foldl (init := a) fun acc k v =>
      acc.setObjVal! k (match oa.get? k with | some w => deepMerge w v | none => v)
  | _, _ => b

def strs (xs : List String) : Json := Json.arr (xs.map Json.str).toArray

/-- `YES`/`NO`, as Xcode writes build settings. -/
def yes (b : Bool) : Json := if b then "YES" else "NO"

def Manifest.testBundleId (m : Manifest) (t : UITests) : String := t.bundleId.getD (m.bundleId ++ ".uitests")

def Manifest.infoPlist (m : Manifest) : Json :=
  let version := match m.version with
    | .fixed short build => [("CFBundleShortVersionString", Json.str short), ("CFBundleVersion", Json.str build)]
    | .settings _ _ => [("CFBundleShortVersionString", "$(MARKETING_VERSION)"), ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)")]
  let orientations := match m.orientations with
    | some (phone, pad) => [("UISupportedInterfaceOrientations", strs (phone.map (·.key))),
                            ("UISupportedInterfaceOrientations~ipad", strs (pad.map (·.key)))]
    | none => []
  let modes := m.backgroundTasks.foldl (fun acc (_, k) => if acc.contains k.mode then acc else acc ++ [k.mode]) []
  let tasks := if m.backgroundTasks.isEmpty then [] else
    [("UIBackgroundModes", strs modes), ("BGTaskSchedulerPermittedIdentifiers", strs (m.backgroundTasks.map (·.1)))]
  let generated := Json.mkObj <|
    [("CFBundleDisplayName", Json.str m.displayName)] ++ version ++ [("UILaunchScreen", Json.mkObj [])] ++
    -- the shell's scene delegate (LeanNativeShell.h)
    [("UIApplicationSceneManifest", Json.mkObj [
        ("UIApplicationSupportsMultipleScenes", false),
        ("UISceneConfigurations", Json.mkObj [("UIWindowSceneSessionRoleApplication", Json.arr #[Json.mkObj [
            ("UISceneConfigurationName", "Default"), ("UISceneDelegateClassName", "LNSceneDelegate")]])])])] ++
    orientations ++ m.usage.map (fun (k, v) => (k, Json.str v)) ++ tasks
  deepMerge generated (Json.mkObj m.info)

def Manifest.entitlementsPlist (m : Manifest) : Json :=
  let icloud := if m.iCloudContainers.isEmpty then [] else
    [("com.apple.developer.icloud-container-identifiers", strs m.iCloudContainers),
     ("com.apple.developer.icloud-services", strs ["CloudKit"])]
  let keychain := if m.keychainGroups.isEmpty then [] else [("keychain-access-groups", strs m.keychainGroups)]
  deepMerge (Json.mkObj (icloud ++ keychain)) (Json.mkObj m.entitlements)

/-- Ad-hoc signed in the simulator: an unsigned app has no Keychain entitlement (errSecMissingEntitlement);
and arm64 only there, as Lean's retargeted libraries are. -/
def simulatorSettings : List (String × Json) :=
  [("CODE_SIGN_IDENTITY[sdk=iphonesimulator*]", "-"), ("CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]", "NO"),
   ("EXCLUDED_ARCHS[sdk=iphonesimulator*]", "x86_64")]

def Manifest.appSettings (m : Manifest) (p : Paths) : Json :=
  let mac : List (String × Json) := match m.mac with
    | .none => [("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", yes false)]
    | .designedForiPad => [("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", yes true)]
    | .catalyst => [("SUPPORTS_MACCATALYST", yes true), ("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER", yes false),
                    ("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", yes false), ("CODE_SIGN_IDENTITY[sdk=macosx*]", "-")]
  let team := match m.team with
    | some t => [("DEVELOPMENT_TEAM", Json.str t), ("CODE_SIGN_STYLE", "Automatic")]
    | none => []
  let version := match m.version with
    | .settings marketing current => [("MARKETING_VERSION", Json.str marketing), ("CURRENT_PROJECT_VERSION", Json.str current)]
    | .fixed _ _ => []
  let icon := if m.icon.isSome then [("ASSETCATALOG_COMPILER_APPICON_NAME", Json.str "AppIcon")] else []
  let entitlements := if m.entitlementsPlist == Json.mkObj [] then []
    else [("CODE_SIGN_ENTITLEMENTS", Json.str s!"{p.build}/{m.name}.entitlements")]
  deepMerge (Json.mkObj <|
    [("PRODUCT_BUNDLE_IDENTIFIER", Json.str m.bundleId), ("PRODUCT_NAME", Json.str m.name),
     ("GENERATE_INFOPLIST_FILE", yes false),
     ("HEADER_SEARCH_PATHS", strs [p.leanInclude, s!"$(PROJECT_DIR)/{p.native}/c"]),
     ("LIBRARY_SEARCH_PATHS", strs [s!"$(PROJECT_DIR)/{p.build}/lib"]),
     ("OTHER_LDFLAGS", strs ["-lLean", "-lStd", "-lInit", "-lleanrt", "-luv", "-lgmp", "-lc++"]),
     -- Lean's generated C at -O3 in every configuration, as Lean builds it
     ("GCC_OPTIMIZATION_LEVEL", "3"), ("DEAD_CODE_STRIPPING", yes true)] ++
    simulatorSettings ++ mac ++ team ++ version ++ icon ++ entitlements) (Json.mkObj m.settings)

def Manifest.testTarget (m : Manifest) (p : Paths) (t : UITests) : Json :=
  let mac : List (String × Json) := match m.mac with
    | .catalyst => [("SUPPORTS_MACCATALYST", yes true), ("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", yes false),
                    ("CODE_SIGN_IDENTITY[sdk=macosx*]", "-")]
    | _ => []
  Json.mkObj [
    ("type", "bundle.ui-testing"), ("platform", "iOS"),
    -- the framework's XCTest kit, in this target only: the app never links XCTest
    ("sources", Json.arr ((t.sources.map Json.str) ++
       [Json.mkObj [("path", Json.str s!"{p.native}/testkit"), ("name", "LeanNativeTestKit")]]).toArray),
    ("dependencies", Json.arr #[Json.mkObj [("target", Json.str m.name)]]),
    ("settings", Json.mkObj [("base", deepMerge (Json.mkObj <|
       [("PRODUCT_BUNDLE_IDENTIFIER", Json.str (m.testBundleId t)), ("GENERATE_INFOPLIST_FILE", yes true),
        ("TEST_TARGET_NAME", Json.str m.name)] ++ simulatorSettings ++ mac) (Json.mkObj m.testSettings))])]

/-- The XcodeGen spec. XcodeGen writes Info.plist and the entitlements into the build directory from it. -/
def Manifest.project (m : Manifest) (p : Paths) : Json :=
  let tests := m.uiTests.map fun t => (m.name ++ "UITests", t)
  let sources : List Json :=
    [Json.mkObj [("path", Json.str s!"{p.build}/native-shell"), ("name", "LeanNativeShell")],
     Json.mkObj [("path", Json.str s!"{p.native}/c"), ("name", "LeanNativeShim")],
     Json.mkObj [("path", Json.str s!"{p.build}/lean-c"), ("name", "LeanC"), ("compilerFlags", strs ["-w"])]] ++
    m.resources.map (fun r => Json.mkObj [("path", Json.str r), ("buildPhase", "resources")]) ++
    m.icon.toList.map (fun i => Json.mkObj [("path", Json.str i)])
  let entitlements := m.entitlementsPlist
  let app := Json.mkObj <|
    ([("type", "application"), ("platform", "iOS"), ("sources", Json.arr sources.toArray),
     ("info", Json.mkObj [("path", Json.str s!"{p.build}/Info.plist"), ("properties", m.infoPlist)]),
     ("settings", Json.mkObj [("base", m.appSettings p)])] : List (String × Json)) ++
    (if entitlements == Json.mkObj [] then [] else
      [("entitlements", Json.mkObj [("path", Json.str s!"{p.build}/{m.name}.entitlements"), ("properties", entitlements)])])
  let targets := [(m.name, app)] ++ tests.toList.map fun (n, t) => (n, m.testTarget p t)
  let scheme := Json.mkObj <|
    [("build", Json.mkObj [("targets", Json.mkObj <|
        [(m.name, Json.str "all")] ++ tests.toList.map fun (n, _) => (n, strs ["test"]))])] ++
    tests.toList.map fun (n, _) => ("test", Json.mkObj [("config", "Debug"), ("targets", strs [n])])
  deepMerge (Json.mkObj [
    ("name", Json.str m.name),
    ("options", Json.mkObj [("deploymentTarget", Json.mkObj [("iOS", Json.str m.deploymentTarget)]),
                            ("xcodeVersion", Json.str m.xcodeVersion)]),
    ("settings", Json.mkObj [("base", Json.mkObj [
        ("IPHONEOS_DEPLOYMENT_TARGET", Json.str m.deploymentTarget),
        ("CLANG_ENABLE_OBJC_ARC", yes true), ("ENABLE_USER_SCRIPT_SANDBOXING", yes true)])]),
    ("targets", Json.mkObj targets),
    ("schemes", Json.mkObj [(m.name, scheme)])]) m.spec

/-! ## What the capabilities need -/

def nonEmptyStr (j : Json) (key : String) : Bool :=
  match j.getObjValAs? String key with
  | .ok s => !s.trimAscii.isEmpty
  | .error _ => false

def strList (j : Json) (key : String) : List String :=
  match j.getObjValAs? (Array String) key with
  | .ok a => a.toList
  | .error _ => []

/-- What each capability family needs before the app may call it, read from the Info.plist and entitlements
the manifest generates (so a key set through `info` or `entitlements` counts): the problems, each naming
the missing key. A family not listed (`keychain.*`, `http.get`, …) needs nothing. -/
def requirements : List (String × (Json → Json → List String)) := [
  -- LocalAuthentication ends the app at its first Face ID prompt without it
  ("auth", fun info _ =>
    if nonEmptyStr info "NSFaceIDUsageDescription" then []
    else ["uses auth, but Info.plist has no NSFaceIDUsageDescription (a usage text)"]),
  -- CoreBluetooth ends the app at its first use without it
  ("ble", fun info _ =>
    if nonEmptyStr info "NSBluetoothAlwaysUsageDescription" then []
    else ["uses ble.*, but Info.plist has no NSBluetoothAlwaysUsageDescription (a usage text)"]),
  -- the shell registers a launch handler per identifier; BGTaskScheduler refuses any other one, and a
  -- task kind without its background mode
  ("bgtask", fun info _ =>
    let ids := strList info "BGTaskSchedulerPermittedIdentifiers"
    let modes := strList info "UIBackgroundModes"
    (if ids.isEmpty then ["uses bgtask.*, but Info.plist has no BGTaskSchedulerPermittedIdentifiers (backgroundTasks)"] else []) ++
    (if modes.contains "fetch" || modes.contains "processing" then []
     else ["uses bgtask.*, but Info.plist's UIBackgroundModes has neither fetch nor processing (backgroundTasks)"])),
  -- CloudKit traps on a missing entitlement (the shell answers missingEntitlement instead, at run time)
  ("cloudkit", fun _ ent =>
    (if (strList ent "com.apple.developer.icloud-services").contains "CloudKit" then []
     else ["uses cloudkit.*, but the entitlements' com.apple.developer.icloud-services has no CloudKit (iCloudContainers)"]) ++
    (if (strList ent "com.apple.developer.icloud-container-identifiers").isEmpty
     then ["uses cloudkit.*, but the entitlements have no com.apple.developer.icloud-container-identifiers (iCloudContainers)"]
     else []))]

/-- `ble.connect` and `ble.*` are both family `ble`. -/
def family (use : String) : String := (use.splitOn ".").headD use

/-- A use names a capability of the shell, or a family (`ble.*`) that has one. -/
def known (use : String) : Bool :=
  if use.endsWith ".*" then capabilities.any (family ·.name == family use)
  else capabilities.any (·.name == use)

def Manifest.problems (m : Manifest) : List String :=
  let ident (s : String) := !s.isEmpty && s.all fun c => c.isAlphanum || c == '_' || c == '-'
  let info := m.infoPlist
  let ent := m.entitlementsPlist
  let families := m.uses.map family |>.eraseDups
  (if ident m.name then [] else [s!"name {repr m.name}: letters, digits, _ and - only"]) ++
  (if m.bundleId.contains '.' then [] else [s!"bundleId {repr m.bundleId}: a reverse-DNS identifier"]) ++
  (m.uses.filter (!known ·) |>.map fun u => s!"uses {u}: the shell has no such capability (LeanNativeShell.capabilities)") ++
  (m.unlisted.filter (!known ·) |>.map fun u => s!"unlisted {u}: the shell has no such capability (LeanNativeShell.capabilities)") ++
  (m.backgroundTasks.filter (·.1.isEmpty) |>.map fun _ => "backgroundTasks: an empty identifier") ++
  (requirements.filter (families.contains ·.1) |>.flatMap fun (_, need) => need info ent)

/-! ## What the app's code calls

`uses` is checked against the capabilities the app's code names. Every call to the shell names its
capability as a string (`{ capability := "ble.connect", … }` in the typed clients, the name passed to a
command in an app's own code), and Lean writes a string literal into the C as it is, in quotes: so the C
that Lean generated for the app's import closure (build-ios's `build/lean-c`, the C the app is built from)
names every capability the app can call. A capability the app imports but never calls is found too: that
asks for one entry too many in `uses`, never one too few. -/

/-- A use covers a capability: its name, or its family (`ble.*`). -/
def covers (use cap : String) : Bool :=
  use == cap || (use.endsWith ".*" && family use == family cap)

/-- The shell's capabilities named, as string literals, in the C of `sources` (file name, text): each with
the first file that names it. -/
def calledIn (sources : List (String × String)) : List (String × String) :=
  capabilities.filterMap fun c =>
    (sources.find? (·.2.contains ("\"" ++ c.name ++ "\""))).map fun (file, _) => (c.name, file)

/-- The calls that `uses` (or `unlisted`) does not cover, one problem per family, naming a capability and
the file it is in. -/
def Manifest.callProblems (m : Manifest) (calls : List (String × String)) : List String :=
  let missing := calls.filter fun (c, _) => !(m.uses ++ m.unlisted).any (covers · c)
  let fams := missing.foldl (fun acc (c, f) => if acc.any (family ·.1 == family c) then acc else acc ++ [(c, f)]) []
  fams.map fun (c, f) =>
    s!"the app calls {c} ({f}), but uses lists neither {c} nor {family c}.* (or unlisted, to call it on purpose without its requirements)"

/-- The entries of `uses` that no call covers: warnings, as a family the code reaches only in a way the C
does not show (a name built at run time) is still needed. -/
def Manifest.unusedUses (m : Manifest) (calls : List (String × String)) : List String :=
  m.uses.filter fun u => !calls.any fun (c, _) => covers u c

/-- The `.c` files of a directory (build-ios's `build/lean-c`), as (file name, text). -/
def readC (dir : System.FilePath) : IO (List (String × String)) := do
  let entries ← dir.readDir
  let cs := entries.toList.filter (·.path.extension == some "c") |>.map (·.path)
  cs.mapM fun f => return ((f.fileName.getD f.toString), ← IO.FS.readFile f)

/-- JSON with every object's keys in ascending order, one entry per line: XcodeGen keeps the spec's order
(targets, so the project's target list), and Lean's own printer writes keys in descending order. -/
partial def render (indent : String := "") : Json → String
  | .obj o =>
    let inner := indent ++ "  "
    if o.isEmpty then "{}" else
    "{\n" ++ ",\n".intercalate (o.toList.map fun (k, v) => inner ++ (Json.str k).compress ++ ": " ++ render inner v) ++
      "\n" ++ indent ++ "}"
  | .arr a =>
    let inner := indent ++ "  "
    if a.isEmpty then "[]" else
    "[\n" ++ ",\n".intercalate (a.toList.map fun v => inner ++ render inner v) ++ "\n" ++ indent ++ "]"
  | j => j.compress

/-- The spec as XcodeGen reads it (JSON), or the manifest's problems. -/
def Manifest.generate (m : Manifest) (p : Paths) : Except (List String) String :=
  match m.problems with
  | [] => .ok (render "" (m.project p) ++ "\n")
  | ps => .error ps

/-- An app's `ios-project` executable:
`lake exe ios-project <spec> --native <dir> --build <dir> --lean-include <dir> [--lean-c <dir>]` writes the
spec (build-ios runs it), or prints the manifest's problems and fails. With `--lean-c` (the app's generated C;
build-ios passes it) it also fails on a capability the C names that `uses` does not cover, and warns about an
entry of `uses` that nothing in the C covers. The file is left alone when its text is unchanged. -/
def Manifest.main (m : Manifest) (args : List String) : IO UInt32 := do
  let usage := "usage: ios-project <spec.json> --native <dir> --build <dir> --lean-include <dir> [--lean-c <dir>]"
  let rec flags : List String → Except String (List (String × String))
    | [] => .ok []
    | f :: v :: rest => if f.startsWith "--" then (((f.drop 2).toString, v) :: ·) <$> flags rest else .error usage
    | _ => .error usage
  let (out :: rest) := args | IO.eprintln usage; return 2
  let .ok fs := flags rest | IO.eprintln usage; return 2
  let get k := (fs.lookup k)
  let (some native, some leanInclude) := (get "native", get "lean-include") | IO.eprintln usage; return 2
  match m.generate { native, leanInclude, build := (get "build").getD "build" } with
  | .error ps =>
    for p in ps do IO.eprintln s!"{m.name} manifest: {p}"
    return 1
  | .ok text =>
    -- with the app's C (build-ios passes it), `uses` is checked against what the code calls
    if let some dir := get "lean-c" then
      let calls := calledIn (← readC dir)
      let ps := m.callProblems calls
      for p in ps do IO.eprintln s!"{m.name} manifest: {p}"
      if !ps.isEmpty then return 1
      for u in m.unusedUses calls do
        IO.eprintln s!"{m.name} manifest: warning: uses lists {u}, but the app's C names no such capability"
    if let some dir := (System.FilePath.mk out).parent then IO.FS.createDirAll dir
    let old ← (try IO.FS.readFile out catch _ => pure "")
    if old != text then IO.FS.writeFile out text
    return 0

end LeanNativeShell
