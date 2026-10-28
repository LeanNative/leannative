# Native mode: full Lean, compiled to C, inside the iOS app

ElmLean has two ways to run an app on iOS:

| | Generated mode (`elmgen`) | Native mode (this directory) |
|---|---|---|
| App code | the subset `elmgen` translates | any Lean 4: recursion, `do`, `IO`, tasks, `ByteArray`, `UInt64`, hash maps… |
| What runs on the phone | Swift printed from the proven definitions | the same definitions compiled by Lean's compiler to C, with Lean's runtime |
| View | a SwiftUI screen printed per app | a generic UIKit renderer of the view tree Lean returns, in Objective-C |
| Effects | commands run by a hand-written Swift host | commands run by the app's own Lean code (`perform`): TCP, files, timers, tasks; iOS-only things through capabilities |
| Swift per app | a ~20-line shell plus the host | none, and none in the shell: it is Objective-C, printed at build time |

Both modes run the same `update`/`view`/`cmds`, so the theorems about an app (and about
`Session.step`) hold in either. Native mode is what an app needs when its logic is too large or too
low-level for the subset — a Bitcoin wallet, for example.

## How an app is built

```
app (Lean package)      lake build ──► .lake/build/ir/*.c   (the app and ElmLean, as C)
                                         │
scripts/ios_lean_sources.sh ─────────────┤ copies the C of the root's import closure,
                                         │ writes elm_app_initialize.c (calls the root initializer),
                                         │ retargets Lean's runtime and stdlib (.a) to iOS
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
(`ElmLean/Native.lean`). See `examples/native-demo` for a complete app with no Swift.

**Retargeting.** Lean ships its runtime and standard library as macOS arm64 static libraries. The
script copies them and rewrites each object's `LC_BUILD_VERSION` (platform 7 = iOS Simulator,
2 = iOS) — `scripts/retarget_ar.py`. Lean does not support this. Verified on the iOS Simulator
(GMP big numbers, tasks, libuv TCP, capabilities); a device build links but has not been run.

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
`{"captured":true|false}` when screen recording or mirroring starts or stops. The app's `App.system`
turns each into a host message (or ignores it); Winnow stops networking in the background and hides
recovery words while the screen is captured.

## Capabilities (`lean/ElmShell/Capabilities.lean`)

What only iOS can do, by name, for any app: `auth` (Face ID / passcode), `build` (`{"debug":…}`: test hooks read their launch environment only in a Debug build, `#if DEBUG`), `keychain.get/set/delete/clear` (`clear` empties a service: a test namespace's reset)
(`set`/`delete` answer the `OSStatus` too; the simulator build is ad-hoc signed, since an unsigned app has
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
`{"error":"bad-proxy"}`),
`open` (a URL outside the app), and Bluetooth Low Energy by service and characteristic UUID: `ble.state`,
`ble.connect` (a peripheral the system already holds connected, else the first a scan finds; answers its
characteristics), `ble.subscribe` (notifications on; iOS pairs here, so it may wait on the user),
`ble.write` (hex, with or without response), `ble.read` (the next notified value, in arrival order per
characteristic) and `ble.close`. Framing and UUIDs are the app's (a Ledger's transport is Winnow's Lean);
the central manager is made on the first `ble.*` request, so an app that never uses Bluetooth never asks
for it, and an app that does declares `NSBluetoothAlwaysUsageDescription`. The app asks with
`Effects.cap name args k`; the answer comes back as the host message `k result`.

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
and iOS. The renderer's `path` of each control must match the tree's `children`
order; that correspondence is tested by driving apps in the simulator, not proven.
