# Native iOS and macOS apps: Lean compiled to C

A LeanNative app (package `elmlean`, see the README's names section) runs on iOS and macOS with the same Lean definitions: any Lean 4 (recursion, `do`, `IO`,
tasks, `ByteArray`, hash maps…) compiled by Lean's compiler to C and linked with Lean's runtime. A shared
Objective-C renderer draws the view tree with UIKit on iOS and Mac Catalyst on macOS. The app runs its
commands in Lean (`perform`: TCP, files, timers, tasks) and requests platform services through
capabilities. No Swift is compiled, per app or in the shell. The native runtime calls `Session.step`,
so its state-transition theorems apply to the transition used by the running app. The renderer and
platform effects remain trusted and tested separately.

## How an app is built

```
app (Lean package)      lake build ──► .lake/build/ir/*.c   (the app and ElmLean, as C)
                                         │
scripts/ios_lean_sources.sh ─────────────┤ copies the C of the root's import closure,
                                         │ writes elm_app_initialize.c (calls the root initializer),
                                         │ retargets Lean's runtime and stdlib (.a) to iOS / Mac Catalyst
                                         ▼
                                         │ runs `lake exe elmshell build/native-shell`: the shell's
                                         │ Objective-C (renderer, store, capabilities), printed from Lean
                                         ▼
Xcode project (project.yml):  build/native-shell  +  c/ (shim)  +  build/lean-c
                              linked with -lLean -lStd -lInit -lleanrt -luv -lgmp -lc++ (build/lib)
```

**The shell is generated, and it is not Swift.** An app in native mode compiles no Swift at all: the
shell is Objective-C on UIKit, held as Lean data in `framework/lean/ElmShell` and printed by `elmshell`,
so it exists only under an app's `build/` (gitignored), rewritten by every `ios_lean_sources.sh` run
(`ElmLeanShell.h`, `ELApp.m`, `ELStore.m`, `ELNode.m`, `ELRender.m`, `ELCapabilities.m`). What follows the
node grammar comes from one table (`ElmShell/Grammar.lean`): a node's decoding (`ELDecode`, every field
present with its default), the renderer's dispatch with one arm per kind (`ELBuild`), which kinds take no
room in a layout (`ELIsOverlay`), the `role`/`style`/`kind` values (from the Lean enums' printers) and
the event functions. `ElmShell/Check.lean` holds the table to the Lean side: the kernel checks that every
`Wire` constructor, enum constructor and `Event` constructor has its row, and the build evaluates that
each row's sample prints through `Wire.toJson` with exactly the row's keys and JSON kinds, and that the
JSON the shell sends for each event parses back (`Event.fromJson?`) to that event; `elmshell` refuses to
write if any of that fails. The capabilities are a table too (`ElmShell/Capabilities.lean`): the doc table
in the header and the dispatch on the name are printed from the same rows. The rest (layout around
screens and tabs, the store's calls into C, the app and scene delegates) is Objective-C written as a tree
of lines and blocks (`ElmShell/ObjC.lean`).

**The renderer** keeps UIKit views in step with each new tree: the view of a node (an `ELBox`) is reused
at the same place for a node of the same kind and updated in place where it can be (containers, text
inputs, switches, sheets), rebuilt otherwise, and left alone when its node did not change, so typing keeps
the caret and a sync in progress does not reset scrolling. A screen whose only content is a `list` is a
grouped list of cards; `sheet` and `alert` present themselves while their node exists (a sheet swiped
away sends `dismiss`); `tabs` use the platform's tab bar and only the selected tab is built. The app is
scene-based (`UIApplicationSceneManifest` names `ELSceneDelegate`); a scene saved by an earlier SwiftUI
build of an app comes back with SwiftUI's own scene delegate, which draws nothing, and is adopted, so an update does not open on an empty
window. Text is not selectable (SwiftUI's `textSelection`); the apps have explicit Copy buttons.

The C is compiled at `-O3` in every configuration (`GCC_OPTIMIZATION_LEVEL: 3` in project.yml):
Lean builds its own C that way, and at Xcode's Debug `-O0` heavy Lean code (key derivation, hashing)
runs about ten times slower.

The app's root module registers it: `initialize ElmLean.Native.register app`
(`ElmLean/Native.lean`). See `examples/native-demo` for a complete app with no Swift. Its Probes tab asks
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
`lipo`s them, so `-lLean … -lgmp` and `LIBRARY_SEARCH_PATHS` stay as they are. The app's project.yml adds

```yaml
SUPPORTS_MACCATALYST: YES
DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO   # the iOS bundle id (one app, one iCloud container)
SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
"CODE_SIGN_IDENTITY[sdk=macosx*]": "-"             # ad-hoc, to run locally; a team identity to ship
```

and builds with `-destination 'generic/platform=macOS,variant=Mac Catalyst'` (both architectures; the app
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
`ELMLEAN_SNAPSHOT` (launch environment) half a second after each render, for runs that cannot capture the
screen; native-demo with `NATIVEDEMO_SELFTEST=1` runs the TCP echo, two background runs and every probe at launch and prints
each answer to stdout:

```
open -n --arch x86_64 --env NATIVEDEMO_SELFTEST=1 --env ELMLEAN_SNAPSHOT=/tmp/demo.png \
  --stdout /tmp/demo.out ios/build/dd-catalyst/Build/Products/Debug-maccatalyst/NativeDemo.app
```

**`lean_initialize`.** Modules that import anything under `Lean` (ElmLean's JSON uses
`Lean.Data.Json`) call `lean_initialize()` first. The toolchain's version starts the whole
compiler, which an app neither needs nor links; the shim defines it as runtime start-up only.

## The C interface (`c/elmlean_native.h`)

`elmlean_boot` (once), `elmlean_start`, `elmlean_event(json)`, `elmlean_drain`,
`elmlean_cap_result(json)`, `elmlean_wait`, `elmlean_system(json)`. Every reply is `{"seq","view","caps"}`: the view in the
wire grammar of PROTOCOL.md and the capability requests queued since the last reply. Lean tasks post
host answers into a mutex-guarded inbox; a shell thread blocks in `elmlean_wait` and the main actor
drains. Threads Lean did not create are registered (`lean_initialize_thread`) on first use.

**System events.** The shell reports what happens to the app, not to a control, through
`elmlean_system`: `{"scene":"active"|"inactive"|"background"}` on every scene-phase change and
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

**Running the work: `ElmLean.Native.BackgroundRun`** (optional; import it). A `BackgroundRun` is one job
that may be expired at any moment: it linearizes start, expiry and the work's end under one lock,
delivers its completion at most once (exactly once when started or expired), and, when expiry wins
while the work runs, cancels the work (`IO.cancel` plus the app's `cancel` hook) and completes only after
the work and its `cleanup` have returned, so a late success is never reported. Cancellation is
cooperative: work that checks neither `IO.checkCanceled` nor anything its hook can interrupt keeps
running, and so does the wait for it. `BackgroundTasks` keeps the runs by identifier: `launch fx id config`
on `{"bgtask":…}`, `expire fx id` on `{"bgtaskExpired":…}` (an expiry with no run is answered
`bgtask.complete false` at once), each run answering `bgtask.complete` with its outcome;
`BackgroundTasks.systemEvent?` reads both events. The module documentation states every race and
failure case, and `ElmLeanTest/BackgroundRun.lean` (`make check`) tests each one with gates. native-demo
runs iOS-launched tasks through it, and its headless selftest runs one run to completion and one past
its deadline (verified on the iOS 27 simulator and under Mac Catalyst on arm64 and x86_64). These are
tests, not proofs.

## Capabilities (`lean/ElmShell/Capabilities.lean`)

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

**Typed clients: `ElmLean.Native.Client.*`** (optional; import them). `Client.Auth`, `Client.Keychain`,
`Client.Http`, `Client.CloudKit` and `Client.Bluetooth` build each capability's arguments from a typed
request and read its answer into a typed result or a `Client.Error`: `denied`, `cancelled`,
`unsupported` (an unknown capability, the platform, a missing entitlement), `malformed` (never read as
a successful default) or `failed`, keeping the shell's error name, code, domain, text and whole answer.
`Keychain.add` is the only create-only operation, and it is the atomic `keychain.add`, never a read
then a write. The raw `Effects.ask`/`cap` stay for everything else. The `name`/`code` of `auth`, the
`status` of `keychain.get`, `keychain.add`, and the `code`/`domain` of `http.get` are additions to the
answers above that leave every existing field as it was. `ElmLeanTest/Clients.lean` (`make check`) reads
`ElmLeanTest/fixtures/clients.json`, written from this section and the capability table rather than from
the decoders, and checks that every capability it names is one the shell offers; native-demo's selftest
calls them against the shell (iOS 27 simulator: `add` then `alreadyExists`, read, delete; Mac Catalyst
ad-hoc: Keychain writes `unsupported`, -34018). The clients check what the shell answers, not what the
platform did: the native side stays trusted.

**Scoped effects: `ElmLean.Native.EffectScope`** (optional; import it). A scope is a part of the app's
life whose effects end together (an open document, an account, a screen): the app `capture`s a token
when work starts and `invalidate`s the scope when that part ends. Invalidation is monotonic; `spawn`
checks the token and registers the task in one step, so a task either never starts or is cancelled and
drained by the invalidation that makes its token stale (`invalidateWithoutWaiting` does the same without making the caller wait); `deliver` drops late results; and
`authenticated` checks the token before the prompt and, after the answer, starts the protected work
through `spawn`, answering `done`, `failed`, `denied`, `cancelled`, `error` or `stale` with the stage. A
validity check does not make later I/O atomic with invalidation, and invalidation cannot undo an
external effect that has started: the module documentation names the linearization points.
`ElmLeanTest/EffectScope.lean` (`make check`) tests invalidation before a spawn, during registration (300
racing rounds), while awaiting authentication, after the answer, during the work, repeatedly, late
replies, failures and cancel-and-drain; `EffectScope.Model` proves only that the pure epoch rule leaves
earlier tokens stale. native-demo's Face ID button runs in a scope that its going to the background ends.
## UI tests: `framework/native/ci/ui-tests` and the XCTest kit (`testkit/`)

`ui-tests` runs an app's XCUITest target on a simulator it creates and deletes, with a recording and
`device.json` and `run.json` (what was tested, recorded as the run starts); the recording is of every
screen the simulator lists that can show the app (not its TV-out, CarPlay or resizable ones), keeping the
one the app drew on, since a device with two integrated screens (iPhone Duo) can otherwise record the
wrong one as a single frame (`recording.json` lists them and the one kept); `UI_BEFORE` / `UI_AFTER` set
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

`testkit/ELTest.{h,m}` are Objective-C helpers for any app's UI-test target, and only for it (add the
directory to the `bundle.ui-testing` target's sources; native-demo's `project.yml` shows how): the app
never links XCTest. `ELElement` finds a node by the identifier the app gives it (`Html.identified`);
`ELTap`, `ELType` (replaces a field's text), `ELWait`, `ELExpectDisabled` and `ELExpectMissing` check
their preconditions first (the element appears, within `ELAppearTimeout`, scrolling for it if a list has
not made it yet; it can be brought into view; it is enabled within `ELEnabledTimeout`) and, when one
fails, record an XCTest failure at the caller's line and return NO without acting; `ELShot` attaches a
screenshot and writes it only where an explicit `ELScreenshots` says (`inDirectory:`, `fromEnvironment:`,
`attachmentsOnly`). `ELText` reads a label without the shell's zero-width wrap points; `ELPoll` and
`ELScrollTo` are the building blocks.

| helper | iOS (device, simulator) | Mac Catalyst |
|---|---|---|
| `ELTap` | tap | click |
| `ELScrollTo` (and the scrolling in the actions) | a drag in the middle of the screen | the scroll wheel over the window |
| `ELType` | tap, delete the old text, type, then the shell's Done bar or return | click, Command-A, type (the field keeps focus) |
| `ELElement`, `ELWait`, `ELExpect*`, `ELShot`, `ELText`, `ELPoll` | the same | the same |

native-demo's `UITests/NativeDemoUITests.m` drives them against its real controls: a counter, text
replacement and clearing, a control the view disables, missing and disabled controls (the failures are
expected and the test checks nothing was tapped), the last button of a list below the fold, a list's end
that always needs scrolling (down to the oldest log row, back up to the first probe), Face ID in the
session's EffectScope ended by going to the background (the system's dismissal or a dropped stale answer),
the selftest through the shell (two BackgroundRuns, an EffectScope drain, the typed clients), and
screenshots written and refused.

CI runs them on both platforms (check.yml): `ui` on an iOS simulator, `ui-catalyst` under Mac Catalyst on
the same GitHub-hosted macOS runner (an arm64 virtual Mac), each with its evidence exported. Under
Catalyst every test runs but Face ID: the click, scroll-wheel and Command-A paths, the selftest (BackgroundRun
and the EffectScope drain as on iOS; the typed Keychain calls answer `unsupported status -34018`, an ad-hoc
Mac app having no keychain access group, and reads `ok none`; HTTP and CloudKit as on iOS), and the
screenshots, which the sandboxed Mac test runner writes to its own temporary directory (the evidence takes
them from the result bundle). Not run under Catalyst: `auth`, whose prompt is the Mac's password sheet in
another process that going to the background does not dismiss, on a runner with no Touch ID; background
tasks, which the Mac never launches (`bgtask.schedule` answers `unavailable`); Bluetooth; and anything
needing a team-signed build (iCloud, a keychain access group). Nothing runs on an x86_64 Mac in CI (the
universal build's x86_64 half ran under Rosetta locally only).

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

The shell (renderer, store, capabilities, C shim) — its Objective-C is printed by `elmshell`, and only
its agreement with the grammar is checked — Lean's compiler and runtime, the retargeted libraries, UIKit
and the iOS and macOS platforms. The renderer's `path` of each control must match the tree's `children`
order; that correspondence is tested by driving apps in the simulator, not proven.
