# Native iOS and macOS apps: Lean compiled to C

A LeanNative app (package `leannative`, see the README's names section) runs on iOS and macOS with the same Lean definitions: any Lean 4 (recursion, `do`, `IO`,
tasks, `ByteArray`, hash maps…) compiled by Lean's compiler to C and linked with Lean's runtime. A shared
Objective-C renderer draws the view tree with UIKit on iOS and Mac Catalyst on macOS. The app runs its
commands in Lean (`perform`: TCP, files, timers, tasks) and requests platform services through
capabilities. No Swift is compiled, per app or in the shell. The native runtime calls `Session.step`,
so its state-transition theorems apply to the transition used by the running app. The renderer and
platform effects remain trusted and tested separately.

## How an app is built

```
app (Lean package)      lake build ──► .lake/build/ir/*.c   (the app and LeanNative, as C)
                                         │
scripts/ios_lean_sources.sh ─────────────┤ copies the C of the root's import closure,
                                         │ writes leannative_app_initialize.c (calls the root initializer),
                                         │ retargets Lean's runtime and stdlib (.a) to iOS / Mac Catalyst
                                         ▼
                                         │ runs `lake exe leannative-shell build/native-shell`: the shell's
                                         │ Objective-C (renderer, store, capabilities), printed from Lean
                                         ▼
                                         │ runs `lake exe ios-project build/project.json`: the XcodeGen
                                         │ spec, from the app's Lean manifest (below)
                                         ▼
Xcode project (XcodeGen):     build/native-shell  +  c/ (shim)  +  build/lean-c
                              linked with -lLean -lStd -lInit -lleanrt -luv -lgmp -lc++ (build/lib)
```

**The shell is generated, and it is not Swift.** An app in native mode compiles no Swift at all: the
shell is Objective-C on UIKit, held as Lean data in `framework/lean/LeanNativeShell` and printed by `leannative-shell`,
so it exists only under an app's `build/` (gitignored), rewritten by every `ios_lean_sources.sh` run
(`LeanNativeShell.h`, `LNApp.m`, `LNStore.m`, `LNNode.m`, `LNRender.m`, `LNCapabilities.m`). What follows the
node grammar comes from one table (`LeanNativeShell/Grammar.lean`): a node's decoding (`LNDecode`, every field
present with its default), the renderer's dispatch with one arm per kind (`LNBuild`), which kinds take no
room in a layout (`LNIsOverlay`), the `role`/`style`/`kind` values (from the Lean enums' printers) and
the event functions. `LeanNativeShell/Check.lean` holds the table to the Lean side: the kernel checks that every
`Wire` constructor, enum constructor and `Event` constructor has its row, and the build evaluates that
each row's sample prints through `Wire.toJson` with exactly the row's keys and JSON kinds, and that the
JSON the shell sends for each event parses back (`Event.fromJson?`) to that event; `leannative-shell` refuses to
write if any of that fails. The capabilities are a table too (`LeanNativeShell/Capabilities.lean`): the doc table
in the header and the dispatch on the name are printed from the same rows. The rest (layout around
screens and tabs, the store's calls into C, the app and scene delegates) is Objective-C written as a tree
of lines and blocks (`LeanNativeShell/ObjC.lean`).

**The renderer** keeps UIKit views in step with each new tree: the view of a node (an `LNBox`) is reused
at the same place for a node of the same kind and updated in place where it can be (containers, text
inputs, switches, sheets), rebuilt otherwise, and left alone when its node did not change, so typing keeps
the caret and a sync in progress does not reset scrolling. A screen whose only content is a `list` is a
grouped list of cards; `sheet` and `alert` present themselves while their node exists (a sheet swiped
away sends `dismiss`); `tabs` use the platform's tab bar and only the selected tab is built. The app is
scene-based (`UIApplicationSceneManifest` names `LNSceneDelegate`); a scene saved by an earlier SwiftUI
build of an app comes back with SwiftUI's own scene delegate, which draws nothing, and is adopted, so an update does not open on an empty
window. Text is not selectable (SwiftUI's `textSelection`); the apps have explicit Copy buttons.

The C is compiled at `-O3` in every configuration (`GCC_OPTIMIZATION_LEVEL: 3`, from the manifest):
Lean builds its own C that way, and at Xcode's Debug `-O0` heavy Lean code (key derivation, hashing)
runs about ten times slower.

The app's root module registers it: `initialize LeanNative.Native.register app`
(`LeanNative/Native.lean`). See `examples/native-demo` for a complete app with no Swift. Its Probes tab asks
for the background-task, CloudKit, iCloud Keychain and SOCKS capabilities and logs the answers and the
system events; `examples/native-demo/socks_probe.py` is the SOCKS5 proxy its HTTP probe expects at
127.0.0.1:1080 (it logs whether the hostname arrived unresolved, ATYP 3).

**Retargeting.** Lean ships its runtime and standard library as macOS static libraries for the host's
architecture (arm64 here). `ios_lean_sources.sh <app> <root> <out> iossim|ios|maccatalyst` copies them and
rewrites each object's `LC_BUILD_VERSION` (platform 7 = iOS Simulator, 2 = iOS, 6 = Mac Catalyst; minos
17.0, the deployment target) — `scripts/retarget_ar.py`. Lean does not support this. `<out>/lib/.platform`
records the platform the libraries were made for, and a run for another platform makes them again, so one
`build/` serves every platform in turn. Verified on the iOS Simulator (GMP big numbers, tasks, libuv TCP,
capabilities) and under Mac Catalyst on both architectures; a device build links but has not been run.

**Mac Catalyst** (`maccatalyst`) builds a universal app, arm64 + x86_64. The x86_64 half of each library
comes from Lean's official macOS x86_64 release of the same version, which only its `lib/` archives are
taken from (nothing from it runs):

```
framework/native/scripts/fetch_lean_x86_64.sh ~/lean-x86_64        # downloads lean-4.35.0-darwin.tar.zst,
export LEAN_X86_64_PREFIX=~/lean-x86_64/lean-4.35.0-darwin          # checks its SHA-256, keeps lib/ + include/
framework/native/scripts/ios_lean_sources.sh <app> <Root> <app>/ios/build maccatalyst
```

(v4.35.0: `https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-darwin.tar.zst`,
SHA-256 `0b43be5c7ecfb36016566a41005ab62bdb04743e6bfd5837e45f796ef4750b4e`, GitHub's published digest; a
new toolchain needs its checksum added to the script.) The script refuses a prefix whose `version.h`
differs from the toolchain's in anything but the platform, retargets both architectures to platform 6 and
`lipo`s them, so `-lLean … -lgmp` and `LIBRARY_SEARCH_PATHS` stay as they are. The app's manifest says
`mac := .catalyst`, which sets

```yaml
SUPPORTS_MACCATALYST: YES
DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO   # the iOS bundle id (one app, one iCloud container)
SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
"CODE_SIGN_IDENTITY[sdk=macosx*]": "-"             # ad-hoc, to run locally; a team identity to ship
```

(the UI-test target gets the same, but for the bundle id), and builds with `-destination 'generic/platform=macOS,variant=Mac Catalyst'` (both architectures; the app
is at `…/Debug-maccatalyst/<App>.app`, its executable under `Contents/MacOS`). The generated C and the shim
have no architecture assumptions. Under Catalyst the window is resizable down to 390×640 points
(`sizeRestrictions`), and the privacy cover goes up only in the background: a Mac window is inactive
whenever another app is in front, and the Mac takes no app-switcher snapshots.

| capability | Mac Catalyst (native-demo, ad-hoc signed, arm64 and x86_64 under Rosetta) |
|---|---|
| `auth` | LocalAuthentication is available (Touch ID or the login password); not exercised headless |
| `keychain.*` | Catalyst uses the data-protection keychain: an ad-hoc build has no keychain access group, so writes answer `status: -34018` (errSecMissingEntitlement) and reads `null`; a build signed with a team identity has one |
| `clipboard.*`, `paths`, `documents`, `exclude-from-backup`, `open`, `build` | available (UIKit's pasteboard is the Mac's) |
| `http.get` | available, SOCKS included (the SOCKS probe answers 200 with ATYP 3) |
| `ble.*` | CoreBluetooth is available; the app declares `NSBluetoothAlwaysUsageDescription` as on iOS |
| `bgtask.*` | handlers register, but the Mac runs no background tasks: `bgtask.schedule` answers `unavailable` (the system's `notPermitted`, renamed), `refreshStatus` answers what UIKit says (`available`) |
| `cloudkit.*` | available with the entitlement; the check reads it from the code signature (a Mac executable has no `__TEXT,__entitlements`), on both slices of a universal binary; ad-hoc builds cannot carry iCloud entitlements, so they answer `missingEntitlement` |
| view nodes | UIKit as on iPad: `share` and action-sheet `alert`s present as popovers from their control; `tabs` are UITabs in the sidebar-adaptable mode, a sidebar in the window; lists keep to a 720 pt column and other content to the readable width |

**Headless runs.** A Debug build of any native app draws its window into the PNG named by
`LEANNATIVE_SNAPSHOT` (launch environment) half a second after each render, for runs that cannot capture the
screen; native-demo with `NATIVEDEMO_SELFTEST=1` runs the TCP echo, two background runs and every probe at launch and prints
each answer to stdout:

```
open -n --arch x86_64 --env NATIVEDEMO_SELFTEST=1 --env LEANNATIVE_SNAPSHOT=/tmp/demo.png \
  --stdout /tmp/demo.out ios/build/dd-catalyst/Build/Products/Debug-maccatalyst/NativeDemo.app
```

**Bluetooth with a real peripheral.** With `NATIVEDEMO_BLE_SERVICE=<service UUID>` in the launch
environment, native-demo's Probes tab gains a Bluetooth section: `BLE state`, and `BLE connect`, which
connects to the first peripheral offering that service (`ble.connect`, 90 s), logs its id and advertised
name (`name` in the answer) and closes the connection. Each answer is logged and printed to stdout as
`ble: …`. It says nothing else to the peripheral: a device's protocol is its app's. Without the variable
the app never touches Bluetooth, so CI and the UI tests are never asked for the Bluetooth permission. A
person runs it, since macOS or iOS asks them to allow Bluetooth the first time:

```
open -n --env NATIVEDEMO_BLE_SERVICE=13d63400-2c97-0004-0000-4c6564676572 --env LEANNATIVE_SNAPSHOT=/tmp/ble.png \
  --stdout /tmp/ble.out …/Debug-maccatalyst/NativeDemo.app     # a Ledger Nano X's advertised service
```

### The Xcode project, from a Lean manifest (`lean/LeanNativeShell/Manifest.lean`)

An app describes its Xcode project once, in Lean, and never writes `project.yml`. Its package has a module
outside the app's import closure (so none of it reaches the app) holding an `LeanNativeShell.Manifest`, and an
executable named `ios-project` running it:

```lean
-- NativeDemo/Project.lean
import LeanNativeShell.Manifest
open LeanNativeShell

def manifest : Manifest where
  name := "NativeDemo"                       -- project, target, scheme, product
  displayName := "Native Demo"
  bundleId := "art.fralex.leannative.nativedemo"
  mac := .catalyst                           -- or .designedForiPad, or .none (the default)
  uses := ["auth", "keychain.*", "http.get", "ble.*", "bgtask.*"]
  usage := [("NSFaceIDUsageDescription", "Shows that a Lean app can ask for Face ID."),
            ("NSBluetoothAlwaysUsageDescription", "Shows that a Lean app can connect to a Bluetooth LE peripheral.")]
  backgroundTasks := [("art.fralex.leannative.nativedemo.refresh", .refresh),
                      ("art.fralex.leannative.nativedemo.processing", .processing)]
  uiTests := some {}                         -- sources: ["UITests"], bundle id + ".uitests"

def main := manifest.main
```

```toml
# lakefile.toml
[[lean_exe]]
name = "ios-project"
root = "NativeDemo.Project"
```

`framework/native/ci/build-ios` (and so `ui-tests` and `ios-app.yml`) runs `lake exe ios-project` after
`ios_lean_sources.sh`: it writes the XcodeGen spec to `ios/build/project.json`, and XcodeGen generates
`ios/<name>.xcodeproj` with `ios/` as its root, writing `build/Info.plist` and, when there are any,
`build/<name>.entitlements`. The app's `ios/` keeps only what cannot be generated: its icon (an asset
catalog, `icon`), its UI tests (Objective-C XCTest) and whatever else it chooses to keep there (native-demo:
its UI-test fixture, `ui-before`, and the entitlements of a team-signed run). An app that still has an
`ios/project.yml` gets XcodeGen on that file, as before, and no manifest is run.

Where each key comes from:

- **The framework, always**: the sources (`build/native-shell` as `LeanNativeShell`, `framework/native/c` as
  `LeanNativeShim`, `build/lean-c` as `LeanC` at `-w`); `LNSceneDelegate` in `UIApplicationSceneManifest`,
  one scene; `UILaunchScreen`; `CLANG_ENABLE_OBJC_ARC` and `ENABLE_USER_SCRIPT_SANDBOXING`; Lean's headers
  (the app's toolchain's `include`, written under `$(HOME)` when it is there) and the shim's; the retargeted
  libraries (`LIBRARY_SEARCH_PATHS`, `OTHER_LDFLAGS`); `GCC_OPTIMIZATION_LEVEL` 3 and dead-code stripping;
  ad-hoc signing and arm64 only in the simulator; `GENERATE_INFOPLIST_FILE: NO`; the UI-test target's test
  kit, `TEST_TARGET_NAME` and the scheme that tests it.
- **The capabilities the app uses** (`uses`, names or families of the shell's capability table, checked
  against it): `usage` texts, `backgroundTasks` (`BGTaskSchedulerPermittedIdentifiers`, and
  `UIBackgroundModes` from their kinds: `fetch` for refresh, `processing` for processing),
  `iCloudContainers` (`com.apple.developer.icloud-container-identifiers` and `icloud-services` CloudKit),
  `keychainGroups` (`keychain-access-groups`). Generation refuses a manifest whose Info.plist or
  entitlements lack what a family it uses needs, and names the key:

  | uses | needs |
  |---|---|
  | `auth` | `NSFaceIDUsageDescription` |
  | `ble.*` | `NSBluetoothAlwaysUsageDescription` |
  | `bgtask.*` | `BGTaskSchedulerPermittedIdentifiers`, and `UIBackgroundModes` with `fetch` or `processing` |
  | `cloudkit.*` | the `com.apple.developer.icloud-services` entitlement holding `CloudKit`, and an `icloud-container-identifiers` one |
  | anything else (`keychain.*`, `http.get`, `clipboard.*`, …) | nothing |

  The check reads the generated plists, so a key set through `info` or `entitlements` counts.

  `uses` is checked against the app's code too. build-ios hands generation the C Lean wrote for the app's
  import closure (`build/lean-c`, `--lean-c`), and every capability the shell has is looked for there as a
  string literal: a call names its capability as a string (`{ capability := "ble.connect", … }` in the typed
  clients, or the name an app passes itself), and Lean writes it into the C as it is. A capability the C
  names whose family `uses` does not cover is refused, naming the capability and its file. An entry of
  `uses` that nothing in the C covers is a warning only. A module the app imports but never calls still
  counts, so the check can ask for one entry too many, never one too few; a name built at run time
  (`"ble." ++ op`) is not seen. `unlisted` names families the app calls on purpose without their
  requirements: native-demo calls `cloudkit.*` with no iCloud container, to show the shell's
  `missingEntitlement` answer.
- **The app**: `name`, `displayName`, `bundleId`, `team` (`DEVELOPMENT_TEAM`, signed automatically),
  `version` (`.fixed short build` into Info.plist, or `.settings marketing current`: `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION`, which a release overrides with xcodebuild arguments), `deploymentTarget`
  (17.0), `xcodeVersion`, `mac`, `orientations` (iPhone, then iPad), `icon`, `resources`, `uiTests`.
- **Anything the manifest does not model**: `info` (Info.plist keys), `entitlements`, `settings` (the app
  target's build settings) and `testSettings` (the UI-test target's) go over the generated values, and
  `spec` is merged into the whole XcodeGen spec last (objects key by key, anything else replaced), so any
  XcodeGen option, target or scheme setting is still the app's to set.

`make check` runs the manifest's tests (`lean/LeanNativeTest/Manifest.lean`): each family refused without its
key and accepted with it, unknown capabilities, and the generated spec, escape hatches included.

**`lean_initialize`.** Modules that import anything under `Lean` (LeanNative's JSON uses
`Lean.Data.Json`) call `lean_initialize()` first. The toolchain's version starts the whole
compiler, which an app neither needs nor links; the shim defines it as runtime start-up only.

## The C interface (`c/leannative.h`)

`leannative_boot` (once), `leannative_start`, `leannative_event(json)`, `leannative_drain`,
`leannative_cap_result(json)`, `leannative_wait`, `leannative_system(json)`. Every reply is `{"seq","view","caps"}`: the view in the
wire grammar of PROTOCOL.md and the capability requests queued since the last reply. Lean tasks post
host answers into a mutex-guarded inbox; a shell thread blocks in `leannative_wait` and the main actor
drains. Threads Lean did not create are registered (`lean_initialize_thread`) on first use.

**System events.** The shell reports what happens to the app, not to a control, through
`leannative_system`: `{"scene":"active"|"inactive"|"background"}` on every scene-phase change and
`{"captured":true|false}` when screen recording or mirroring starts or stops,
`{"bgtask":{"id":…,"kind":"refresh"|"processing"}}` when iOS launches one of the app's background tasks
and `{"bgtaskExpired":{"id":…,"kind":…}}` when it expires one. The app's `App.system` turns each into a
host message (or ignores it); Winnow stops networking in the background and hides recovery words while
the screen is captured.

**Background tasks.** iOS takes launch handlers only before the app finishes launching, so the shell
registers one for every identifier in the app's Info.plist `BGTaskSchedulerPermittedIdentifiers`, first
thing in `didFinishLaunching` (refresh tasks also need `UIBackgroundModes` `fetch`, processing tasks
`processing`). The app asks for a run with `bgtask.schedule`
(`{"id":…,"kind":"refresh"|"processing","after":s,"requiresNetwork":bool,"requiresPower":bool}`, all but
`id` optional; it replaces that identifier's earlier request; iOS decides when, and whether, it runs).
When the task launches the app hears `{"bgtask":…}`, does its work, and answers
`bgtask.complete {"id":…,"success":bool}`. On expiration it hears `{"bgtaskExpired":…}` and should stop
and complete; a task still pending one second later is completed by the shell with `success: false`
(a later `bgtask.complete` answers `{"ok":false,"error":"notPending"}`). `bgtask.refreshStatus` answers
`{"status":"available"|"denied"|"restricted"}` (Background App Refresh). A system event that arrives
before the store has started (a task launched early) starts it. The simulator refuses every request
(`bgtask.schedule` answers `unavailable`), so launches and expirations can only be exercised on a device,
where Xcode's debugger launches a scheduled task with
`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"…"]`.

**Running the work: `LeanNative.Native.BackgroundRun`** (optional; import it). A `BackgroundRun` is one job
that may be expired at any moment: it linearizes start, expiry and the work's end under one lock,
delivers its completion at most once (exactly once when started or expired), and, when expiry wins
while the work runs, cancels the work (`IO.cancel` plus the app's `cancel` hook) and completes only after
the work and its `cleanup` have returned, so a late success is never reported. Cancellation is
cooperative: work that checks neither `IO.checkCanceled` nor anything its hook can interrupt keeps
running, and so does the wait for it. `BackgroundTasks` keeps the runs by identifier: `launch fx id config`
on `{"bgtask":…}`, `expire fx id` on `{"bgtaskExpired":…}` (an expiry with no run is answered
`bgtask.complete false` at once), each run answering `bgtask.complete` with its outcome;
`BackgroundTasks.systemEvent?` reads both events. The module documentation states every race and
failure case, and `LeanNativeTest/BackgroundRun.lean` (`make check`) tests each one with gates. native-demo
runs iOS-launched tasks through it, and its headless selftest runs one run to completion and one past
its deadline (verified on the iOS 27 simulator and under Mac Catalyst on arm64 and x86_64). These are
tests, not proofs.

## Capabilities (`lean/LeanNativeShell/Capabilities.lean`)

What only iOS can do, by name, for any app: `auth` (Face ID / passcode; a failure answers the `LAError` as
`name` and `code` beside the system's text, so a cancellation is told from a denial), `build` (`{"debug":…}`: test hooks read their launch environment only in a Debug build, `#if DEBUG`), `keychain.get/set/add/delete/clear` (`clear` empties a service: a test namespace's reset; `add` creates an
item only if there is none, one `SecItemAdd` that answers `-25299` with `"exists":true` otherwise, where
`set` replaces whatever is there)
(`get`, `set`, `add` and `delete` answer the `OSStatus` too, `-25300` for no such item; the simulator build is ad-hoc signed, since an unsigned app has
no Keychain entitlement and every write fails with -34018; items are this device only unless the request
says `synchronizable`: true, which names iCloud Keychain items instead, accessible while unlocked, and
matches only those; `set` takes raw bytes as `hex` in place of a UTF-8 `value`, and `get` with `hex`: true
answers `{"hex":…|null}`, for keys that are not text),
`clipboard.get/set` (`set` takes `localOnly` and `expiresIn` seconds: kept off Universal Clipboard and
cleared after that time), `paths`, `exclude-from-backup` (with `complete`: also `FileProtectionType.complete`), `documents` (the Documents path, for Lean's file I/O), `http.get` (HTTPS through
URLSession: ephemeral, same-host redirects only, never https→http — Lean's runtime has no TLS; with
`"socks":{"host":…,"port":…}` the request goes through that SOCKS5 proxy, a Tor daemon say: the hostname
is sent to the proxy unresolved, there is no fallback to a direct connection, request and resource time
out after 90 s and 180 s, and a host that is not a string or a port outside 1…65535 answers
`{"error":"bad-proxy"}`; a system error answers its text with its `code` and `domain`),
`open` (a URL outside the app), `bgtask.schedule/complete/refreshStatus` (background tasks, above),
`cloudkit.account/query/save/load/delete` (below), and Bluetooth Low Energy by service and characteristic UUID: `ble.state`,
`ble.connect` (a peripheral the system already holds connected, else the first a scan finds; answers its
characteristics), `ble.subscribe` (notifications on; iOS pairs here, so it may wait on the user),
`ble.write` (hex, with or without response), `ble.read` (the next notified value, in arrival order per
characteristic) and `ble.close`. Framing and UUIDs are the app's (a Ledger's transport is Winnow's Lean);
the central manager is made on the first `ble.*` request, so an app that never uses Bluetooth never asks
for it, and an app that does declares `NSBluetoothAlwaysUsageDescription`. The app asks with
`Effects.cap name args k`; the answer comes back as the host message `k result`.

**CloudKit.** Records in the private database of the app's default container (or `container`, an
identifier), default zone. A field is a string, a number, `{"date":s}` (seconds since 1970), `{"hex":…}`
(bytes) or a list of those; a record answers as
`{"name":…,"type":…,"fields":{…},"modified":s|null,"tag":…|null}`, with an asset field as `{"asset":true}`
and a reference as `{"ref":name}`. One asset per record travels as bytes (hex), under `assetField`
(default `asset`).

| request | answer |
|---|---|
| `cloudkit.account {}` | `{"status":"available","user":recordName}`, or `noAccount` / `restricted` / `couldNotDetermine` / `temporarilyUnavailable` with `"user":null` |
| `cloudkit.query {"type","equals"?:{field:value},"sortBy"?,"ascending"?,"keys"?:[…],"limit"?}` | `{"records":[record…],"more":bool}` (cursors followed up to `limit`, default 100, at most 500) |
| `cloudkit.save {"type","name","fields"?:{…},"asset"?:hex,"assetField"?}` | `{"ok":true,"record":record}`: made or updated, only the given fields change (`changedKeys`), atomically |
| `cloudkit.load {"name","maxBytes"?,"assetField"?}` | `{"record":record,"asset":hex\|null}`; an asset over `maxBytes` (32 MiB) answers `{"error":"tooLarge"}` |
| `cloudkit.delete {"name"}` | `{"ok":true}`, also when there was no such record |

Errors are `{"error":name,"code":n,"detail":…,"retryAfter":s?}`, the name being the `CKErrorCode` case in
lower camel case (`notAuthenticated`, `networkUnavailable`, `networkFailure`, `serviceUnavailable`,
`requestRateLimited`, `zoneBusy`, `quotaExceeded`, `serverRecordChanged`, `permissionFailure`,
`limitExceeded`, `accountTemporarilyUnavailable`, …), except `notFound` for an unknown item; a partial
failure answers its record's own error; `badArgs` is a malformed request. An asset goes up from a
temporary file written with complete file protection and removed when the save ends. The app needs the
iCloud entitlement with CloudKit (`com.apple.developer.icloud-services` `[CloudKit]` and the container in
`com.apple.developer.icloud-container-identifiers`; `iCloud.<bundle id>` for the default container).
Without it CloudKit kills the app when the container is made (a trap, not a catchable exception), so the
shell first reads the app's own entitlements from its signature — iOS has no public API for them: the
simulator build carries them in the executable's `__TEXT,__entitlements` section, a device build in the
entitlements blob of the code signature — and when they lack CloudKit or the container, every
`cloudkit.*` request answers `{"error":"missingEntitlement","detail":…}` without touching CloudKit. (In the
simulator, native-demo answers `missingEntitlement`; built with the entitlement it answers
`{"status":"noAccount","user":null}` and a query `notAuthenticated`.)

**Typed clients: `LeanNative.Native.Client.*`** (optional; import them). `Client.Auth`, `Client.Keychain`,
`Client.Http`, `Client.CloudKit` and `Client.Bluetooth` build each capability's arguments from a typed
request and read its answer into a typed result or a `Client.Error`: `denied`, `cancelled`,
`unsupported` (an unknown capability, the platform, a missing entitlement), `malformed` (never read as
a successful default) or `failed`, keeping the shell's error name, code, domain, text and whole answer.
`Keychain.add` is the only create-only operation, and it is the atomic `keychain.add`, never a read
then a write. The raw `Effects.ask`/`cap` stay for everything else. The `name`/`code` of `auth`, the
`status` of `keychain.get`, `keychain.add`, and the `code`/`domain` of `http.get` are additions to the
answers above that leave every existing field as it was. `LeanNativeTest/Clients.lean` (`make check`) reads
`LeanNativeTest/fixtures/clients.json`, written from this section and the capability table rather than from
the decoders, and checks that every capability it names is one the shell offers; native-demo's selftest
calls them against the shell (iOS 27 simulator: `add` then `alreadyExists`, read, delete; Mac Catalyst
ad-hoc: Keychain writes `unsupported`, -34018). The clients check what the shell answers, not what the
platform did: the native side stays trusted.

**Scoped effects: `LeanNative.Native.EffectScope`** (optional; import it). A scope is a part of the app's
life whose effects end together (an open document, an account, a screen): the app `capture`s a token
when work starts and `invalidate`s the scope when that part ends. Invalidation is monotonic; `spawn`
checks the token and registers the task in one step, so a task either never starts or is cancelled and
drained by the invalidation that makes its token stale (`invalidateWithoutWaiting` does the same without making the caller wait); `deliver` drops late results; and
`authenticated` checks the token before the prompt and, after the answer, starts the protected work
through `spawn`, answering `done`, `failed`, `denied`, `cancelled`, `error` or `stale` with the stage. A
validity check does not make later I/O atomic with invalidation, and invalidation cannot undo an
external effect that has started: the module documentation names the linearization points.
`LeanNativeTest/EffectScope.lean` (`make check`) tests invalidation before a spawn, during registration (300
racing rounds), while awaiting authentication, after the answer, during the work, repeatedly, late
replies, failures and cancel-and-drain; `EffectScope.Model` proves only that the pure epoch rule leaves
earlier tokens stale. native-demo's Face ID button runs in a scope that its going to the background ends.
## UI tests: `framework/native/ci/ui-tests` and the XCTest kit (`testkit/`)

`ui-tests` runs an app's XCUITest target on a simulator it creates and deletes, with a recording and
`device.json` and `run.json` (what was tested, recorded as the run starts); the recording is one
`recordVideo` of the screen simctl names `primary` (`ci/sim-screens`): left to choose, recordVideo has
taken a two-screen iPhone Duo's other screen (one frame for a whole run), and two recorders at once left the
primary one empty. `recording.json` lists the screens, the one recorded and the recording's length against
the run's, and the CI log warns when it is truncated; `UI_BEFORE` / `UI_AFTER` set
up and take down a fixture, and each `KEY=VALUE` line `UI_BEFORE` leaves in `<UI_OUT>/test-env` reaches the
tests' environment. Run native-demo's:

```
APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo \
  UI_BEFORE="$PWD/examples/native-demo/ios/ui-before" framework/native/ci/ui-tests
python3 -I framework/native/ci/export-evidence examples/native-demo/ios/build/ui-tests /tmp/demo-evidence
```

`UI_PLATFORM=maccatalyst` (with `LEAN_X86_64_PREFIX`, as for the Catalyst build) runs the same target as a
Mac Catalyst app on the Mac itself, in its logged-in session: the tests move the real pointer and type on
the real keyboard, so it is for a CI runner, not a Mac in use. `run.json` records the platform as
`Mac Catalyst` and `device.json` the Mac (model, macOS version and build, architecture); the recording
is `screencapture -v` (stopped at the end, never left to hold the run open), converted to `<name>.mp4` by `avconvert`, and needs the Screen Recording
permission (`recording.log` says why there is none). `export-evidence` refuses a run whose `run.json`
platform and result bundle disagree, so a Catalyst run is never recorded as a simulator run or the
reverse.

`testkit/LNTest.{h,m}` are Objective-C helpers for any app's UI-test target, and only for it (a manifest
with `uiTests` adds the directory to that target's sources, and to no other): the app
never links XCTest. `LNElement` finds a node by the identifier the app gives it (`Html.identified`);
`LNTap`, `LNType` (replaces a field's text), `LNWait`, `LNExpectDisabled` and `LNExpectMissing` check
their preconditions first (the element appears, within `LNAppearTimeout`, scrolling for it if a list has
not made it yet; it can be brought into view; it is enabled within `LNEnabledTimeout`) and, when one
fails, record an XCTest failure at the caller's line and return NO without acting; `LNShot` attaches a
screenshot and writes it only where an explicit `LNScreenshots` says (`inDirectory:`, `fromEnvironment:`,
`attachmentsOnly`). `LNText` reads a label without the shell's zero-width wrap points; `LNPoll` and
`LNScrollTo` are the building blocks.

| helper | iOS (device, simulator) | Mac Catalyst |
|---|---|---|
| `LNTap` | tap | click |
| `LNScrollTo` (and the scrolling in the actions) | a drag in the middle of the screen | the scroll wheel over the window |
| `LNType` | tap, delete the old text, type, then the shell's Done bar or return | click, Command-A, type (the field keeps focus) |
| `LNElement`, `LNWait`, `LNExpect*`, `LNShot`, `LNText`, `LNPoll` | the same | the same |

native-demo's `UITests/NativeDemoUITests.m` drives them against its real controls: a counter, text
replacement and clearing, a control the view disables, missing and disabled controls (the failures are
expected and the test checks nothing was tapped), the last button of a list below the fold, a list's end
that always needs scrolling (down to the oldest log row, back up to the first probe), Face ID in the
session's EffectScope ended by going to the background (the system's dismissal or a dropped stale answer),
the selftest through the shell (two BackgroundRuns, an EffectScope drain, the typed clients), and
screenshots written and refused.

### Journeys: UI tests as Lean programs on the host

An app can write its UI tests in Lean instead (`LeanNative.Journey`, framework/lean/LeanNative/Journey.lean):
a journey executable runs on the Mac and sends each step (`launch`, `tap`, `press`, `type`, `text`, `waitFor`,
`shot`, …) to `testkit/LNDriver.m`, one XCUITest the same for every app, which carries it out with the kit's
checks and answers. The checks are the journey's, in Lean, against whatever the host has: the app's own
`update`, a node, a file. `ui-tests` runs it when given `UI_JOURNEY` (the executable): it starts it once
`UI_BEFORE` has run (test-env's lines are in its environment), waits for `<UI_OUT>/driver-port`, and runs
`xcodebuild test -only-testing:<SCHEME>UITests/LNDriver/testDrive` with the port. A failed journey is an
XCTest failure with its message, the next journey still runs, and `journeys.json` has each one's result and
time; `shot` writes `<UI_OUT>/screenshots/<name>.png` and attaches it. Without the port the driver skips, so
an app's Objective-C tests run as before. Simulator only for now: the Mac Catalyst test runner is sandboxed.
native-demo's are `NativeDemo/Journeys.lean` (the same counter, typing, refusals, scrolling and screenshots
as its Objective-C tests):

```
(cd examples/native-demo && lake build journeys)
APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo \
  UI_JOURNEY="$PWD/examples/native-demo/.lake/build/bin/journeys" framework/native/ci/ui-tests
```

`ios-app.yml` takes `ui-journey:`, the name of the app package's executable, then any journey names: built, then run as `UI_JOURNEY` (`ui-journey: journeys counting` runs only `counting`).

CI runs them on both platforms (check.yml): `ui` on an iOS simulator, `ui-catalyst` under Mac Catalyst on
the same GitHub-hosted macOS runner (an arm64 virtual Mac), each with its evidence exported. Under
Catalyst every test runs but Face ID: the click, scroll-wheel and Command-A paths, the selftest (BackgroundRun
and the EffectScope drain as on iOS; the typed Keychain calls answer `unsupported status -34018`, an ad-hoc
Mac app having no keychain access group, and reads `ok none`; HTTP and CloudKit as on iOS), and the
screenshots, which the sandboxed Mac test runner writes to its own temporary directory (the evidence takes
them from the result bundle). Not run under Catalyst: `auth`, whose prompt is the Mac's password sheet in
another process that going to the background does not dismiss, on a runner with no Touch ID; background
tasks, which the Mac never launches (`bgtask.schedule` answers `unavailable`); Bluetooth; and anything
needing a team-signed build in CI (iCloud, a keychain access group).

**Team-signed, on a Mac of your own.** A development build signed with your team gets a keychain access
group, and the Keychain answers as on iOS (native-demo's selftest: `add` then `alreadyExists`, read,
delete; checked on an M5 Max with macOS 27.0.1 and Xcode 27.1). Pass the signing as build settings, so
nothing committed changes; with no `-allowProvisioningUpdates`, Xcode uses the team profiles already on
the Mac (a Mac Catalyst team profile that lists the Mac) and asks Apple for nothing:

```
SIGN=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team> "CODE_SIGN_IDENTITY=Apple Development"
      CODE_SIGN_ENTITLEMENTS="$PWD/examples/native-demo/ios/NativeDemo-team.entitlements")
# the selftest, headless: no UI test, nothing takes over the Mac
PREPARE_ONLY=1 APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo \
  framework/native/ci/build-ios Debug maccatalyst
xcodebuild -project examples/native-demo/ios/NativeDemo.xcodeproj -scheme NativeDemo \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' -derivedDataPath /tmp/dd-team "${SIGN[@]}" build
open -n --env NATIVEDEMO_SELFTEST=1 --stdout /tmp/selftest.out /tmp/dd-team/Build/Products/Debug-maccatalyst/NativeDemo.app
# the UI tests: they take over the pointer and keyboard; no recording of the whole screen
TEST_RUNNER_NATIVEDEMO_KEYCHAIN=access-group UI_PLATFORM=maccatalyst UI_RECORDING=none \
  APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo framework/native/ci/ui-tests "${SIGN[@]}"
```

The UI tests need macOS's Automation Mode, which a Mac that asks for authentication to enable it
(`automationmodetool` says which) prompts for on the first run: someone at the Mac answers it, or enables
it beforehand with `sudo automationmodetool enable-automationmode-without-authentication`.
`TEST_RUNNER_NATIVEDEMO_KEYCHAIN=access-group` tells the selftest test to expect the real Keychain rather
than `-34018`.

## View nodes

Native mode renders the original eight nodes plus `input` (plain / secure / multiline / number / decimal),
`list`, `section`, `labeled`, `screen` (title, back, `toolbar`, pull to refresh: a `click` on the screen; the spinner stays until the next view after its reply, at most 10 s), `tabs`, `sheet`, `alert`, `picker`,
`progress`, `icon`, `qr`, `share` (text, or a file by path), `link`, `page` (a bundled HTML file: scripts off, every
non-file request blocked by a content rule list, `embedded` added to `<body>`; a screen or sheet holding
a page gives it the remaining space instead of scrolling),
`empty`, `disclosure` and `stepper` (its optional `detail`, e.g. "2 of 3", is shown as a labeled value in place of the number), with the events `select n` and `dismiss` (PROTOCOL.md). Every
constructor has its `Sat` case, so `advertises_iff` and the `Spec`/`CmdSpec` theorems cover them.
While the scene is not active the shell covers the window (app-switcher snapshots never show it).
A screen whose title changes is a new screen to the renderer: it starts scrolled to its top.

## What is trusted

The shell (renderer, store, capabilities, C shim) — its Objective-C is printed by `leannative-shell`, and only
its agreement with the grammar is checked — Lean's compiler and runtime, the retargeted libraries, UIKit
and the iOS and macOS platforms. The renderer's `path` of each control must match the tree's `children`
order; that correspondence is tested by driving apps in the simulator, not proven.
