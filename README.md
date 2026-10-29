# LeanNative — native iOS and macOS apps in Lean 4

**Write your app in Lean. Prove the state transitions that matter.**

LeanNative (formerly ElmLean) is a framework for building native apps for **iPhone, iPad, and Mac**. Write your model,
messages, updates, views, and commands in Lean 4. Lean compiles the application to C; a shared
Objective-C shell renders its views with UIKit on iOS and Mac Catalyst on macOS.

The same state-transition functions you test and reason about run in the app. You can add proofs of
your application's invariants and have Lean check them when you build. The application follows the Elm
architecture (`Model`, `Msg`, `update`, `view`), with explicit commands for effects. No Swift is compiled
or written per app.

## What you get

* **Native Apple interfaces.** Lists, navigation, tabs, sheets, toolbars, text input, sharing, and other
  controls rendered by the shared UIKit shell. On macOS, the shell uses Mac Catalyst, including
  resizable windows, sidebar tabs, and popovers.
* **One application model.** The model, updates, and views used in headless tests are the definitions
  compiled into the native app.
* **Proofs about application behavior.** State the invariants your app needs and prove that its updates
  preserve them. The framework supplies proofs about dispatch and sessions; each app supplies its own
  application-specific proofs.
* **Apple platform capabilities.** Device authentication, Keychain, clipboard, file protection, HTTPS,
  CloudKit, Bluetooth LE, and iOS background tasks are available through the shell. Availability and
  signing requirements differ by platform; see the [native platform guide](framework/native/README.md).

LeanNative is being developed alongside [Winnow](https://github.com/winnowwallet/winnow-lean), a Bitcoin
wallet written in Lean. Start with [`examples/native-demo`](examples/native-demo) for a smaller app that
exercises the framework's controls and capabilities.

## Current scope and limits

* **iOS and macOS are the application targets.** The Mac implementation uses Mac Catalyst. An AppKit
  renderer is not implemented.
* **Application proofs are explicit.** Using Lean does not automatically prove an app correct. A proof
  covers the property it states and its assumptions; the native renderer, platform effects, compiler,
  and runtime remain part of the trusted system. See [What is trusted](#what-is-trusted).
* **The native runtime integration is experimental.** The build currently retargets Lean's macOS static
  libraries by rewriting their platform metadata. This is not a supported Lean cross-compilation path.
  The [native platform guide](framework/native/README.md) records the validation performed and the
  remaining device and platform limitations. The reusable app workflow currently covers iOS builds
  and simulator tests; Mac Catalyst validation is documented separately.

## Names: LeanNative and the ElmLean identifiers

The project was called ElmLean until 2026-10-29, at [posix4e/elmlean](https://github.com/posix4e/elmlean);
its home is now [LeanNative/leannative](https://github.com/LeanNative/leannative), with the same history
and tags (`v0.1.0` is `ccbb1b4`). The code keeps its names, so existing apps build unchanged:

| Identifier | Stays |
|---|---|
| Lake package | `elmlean` (`[[require]] name = "elmlean"`, subDir `framework/lean`) |
| Libraries and namespaces | `ElmLean`, `ElmLean.*`, `ElmShell` |
| Executable | `lake exe elmshell` |
| Shell symbols | `elmlean_*` C entry points, `EL*` Objective-C classes |
| Reusable workflow input | `elmlean: <commit>` |

Only the repository path changes for an app: its git source and the workflow's `uses:` must name
`LeanNative/leannative` explicitly, because GitHub Actions does not follow repository redirects for
reusable workflows. Renaming the identifiers would be a separate, versioned migration. Issues moved from
the old tracker are listed in [docs/ISSUES.md](docs/ISSUES.md).

## From Lean to a native app

An app is an ordinary Lean package that depends on the framework. Lean's compiler generates C for the
app and framework; the native build links it with Lean's runtime and the shared shell.

```
        your app: Model · Msg · update · view : Model → Html Msg · cmds · perform · theorems
                                    │
                     lake build ──► the app and ElmLean as C (.lake/build/ir)
                                    │
     framework/native/scripts/ios_lean_sources.sh: the C of the app's import closure, Lean's runtime
                                    │  retargeted to iOS / Mac Catalyst, and the shell printed from Lean
                                    ▼                  (`lake exe elmshell`, checked against the grammar)
                    Xcode (project.yml): one iOS / Mac Catalyst app, no Swift
```

## What an app is

**The UI language.** `Html msg` (`framework/lean/ElmLean/Html.lean`): text, rows and columns, buttons,
fields and inputs, toggles, lists and sections, screens with toolbars, tabs, sheets, alerts, pickers,
steppers, QR codes, share sheets, bundled pages and more. Because `view : Model → Html Msg` is typed, a
view can only emit messages `update` handles: Elm's core guarantee, from the type checker.

**Commands.** `cmds : Msg → Model → List Cmd` are the commands a message asks for, in the same pre-state
`update` sees; `host : Host → Msg` is the only way an answer enters the app (`ElmLean/Cmd.lean`). In
native mode the app runs its own commands: `perform : Cmd → Effects Host → IO Unit`
(`ElmLean/Native.lean`) may start Lean tasks (TCP over Lean's libuv, files, timers) that answer with
`post` from any thread, or ask the shell for a capability with `cap`. The app registers itself in its
root module: `initialize ElmLean.Native.register app`.

**Capabilities.** What only the platform can do, by name, for any app: device authentication, the
Keychain (device-only and iCloud), clipboard, paths and file protection, HTTPS (with SOCKS5), opening
URLs, background tasks, CloudKit, and Bluetooth LE ([framework/native/README.md](framework/native/README.md)).

**The proofs.** A `Spec app` (`ElmLean/Spec.lean`) is three obligations: `init_inv` (your invariant holds
initially), `update_inv` (every message preserves it) and `view_sat` (every handler in the view of a
model with the invariant yields a message satisfying your `Target`). `CmdSpec` is the same for an app with
commands. The framework turns those into guarantees about every session:

| Theorem (namespace `ElmLean`) | Guarantee, for any app |
|---|---|
| `Html.advertises_iff` | A `(path, event)` pair is advertised by the wire tree **iff** dispatching it on the real view yields a message. Nothing un-advertised can trigger anything. |
| `Html.Sat.dispatch`, `Html.Sat.of_forall` | If every handler satisfies a predicate, so does every dispatched message. |
| `Session.handle_advertised`, `Session.handle_dispatch` | An in-sync advertised request is answered with a new view at `seq + 1`, by running `update` on the dispatched message. |
| `Session.start_coherent`, `Session.handle_coherent`, `Session.run_coherent`, `Session.reach_coherent` | The session always shows the view of its current model. |
| `Session.handle_inv`, `Session.run_inv`, `Spec.reachable_inv`, `Spec.reachable_sound` | Any invariant preserved by `update` holds after any trace, and dispatch is well targeted. |
| `Session.step_origin`, `CmdSpec.reachable_inv`, `CmdSpec.trace_origin` | Apps with commands: every step runs `update` on at most one message and asks for exactly `cmds` of it, and that message is an in-sync dispatch from the view shown or a host answer through `app.host`. |

The native runtime calls `Session.step` to process events, so these theorems apply to the state
transition used by the running app. The renderer and the execution of effects have separate trust
and testing requirements, described below.

**The gate.** A gate file lists the theorems an app advertises and scans the rest:

```lean
import ElmLean.Gate
import Notes.Proofs
#assert_axioms Notes.update_inv
#assert_all_axioms ElmLean Notes
```

`#assert_axioms` fails the build if a theorem depends on anything beyond `propext`, `Quot.sound` and
`Classical.choice`, so a `sorry` cannot hide; `framework/scripts/check-axioms.sh` also greps the build log
for `sorry` warnings in definitions.

**The CLI.** `ElmLean.Cli.main app` / `ElmLean.CmdCli.main app` make an app a command-line program that
speaks the wire protocol ([PROTOCOL.md](PROTOCOL.md)) on stdin/stdout: `selftest` explores the app from its
initial model and re-checks at run time what the theorems state, and `framework/scripts/protocol_test.py`
drives it. It is the same `update`/`view`, run without the phone.

## Building an app for iOS and macOS

```bash
cd my-app && lake build
.lake/packages/elmlean/framework/native/scripts/ios_lean_sources.sh . MyApp ios/build iossim
cd ios && xcodegen generate && xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' build
```

`ios_lean_sources.sh` takes `iossim`, `ios` or `maccatalyst`. The app's `ios/project.yml` compiles
`build/native-shell`, `framework/native/c` and `build/lean-c`, and links Lean's libraries from
`build/lib` (see `examples/native-demo/ios/project.yml`). `framework/native/ci/build-ios` does all of the
above for one configuration and platform.

Prerequisites on a Mac with Xcode: `elan` (the toolchain is pinned per package by `lean-toolchain`) and
XcodeGen (`framework/native/ci/install-xcodegen` installs the audited release).

For macOS, use the `maccatalyst` build target. The current build produces a universal arm64/x86_64 app
and needs the matching x86_64 Lean libraries as well as the host toolchain. Follow the
[Mac Catalyst setup and build instructions](framework/native/README.md#how-an-app-is-built) in the native
platform guide. Some capabilities require a team-signed app, and iOS background-task scheduling is
unavailable on macOS.

## Continuous integration for an app

`.github/workflows/ios-app.yml` is a reusable workflow that builds and tests a LeanNative app on GitHub
Actions. It builds every Lean target once, in one job, and keeps the build in the Actions cache; the test
jobs restore it read-only and run in parallel:

| Job | Runs |
|---|---|
| `build` | elan and the toolchain, `lake build` of the app's packages and test executables, the app's `prepare` command; the only job that saves the cache |
| `tests` | each line of `tests`: a Lean test executable or any command, streamed |
| `extra` | the app's own command (Winnow: its tests against a regtest Bitcoin node) |
| `app` | the iOS app: Debug and Release for the simulator, Release for devices (unsigned), each checked for Swift (`check-no-swift`); the app's `release-check`; the UI tests on a throwaway simulator with a screen recording (`ui-tests`) |

Every long step prints its output as it comes, and a line at least every 30 seconds while a step is
quiet (`framework/native/ci/progress`). An app calls it with its own paths and hooks:

```yaml
jobs:
  app:
    uses: LeanNative/leannative/.github/workflows/ios-app.yml@<commit>
    with:
      elmlean: <commit>            # the same commit; checked against the app's lake-manifest.json
      lean-packages: Lean LeanApp
      app-dir: LeanApp
      app-root: MyApp
      scheme: MyApp
      tests: |
        Lean .lake/build/bin/my-test
```

The inputs are documented at the top of the workflow.

## What is trusted

| Layer | Status | How it is checked |
|---|---|---|
| Framework properties of `Html`, `Wire`, `toWire`, `dispatch`, `Session`, `Spec`, and `CmdSpec` | **Proven** | the framework's proof gate |
| An app's `update`/`view`/`cmds` | Application-specific | the app's supplied invariants, proofs, and proof gate; using the framework alone does not prove them |
| JSON codecs, the CLI loop, `ElmLean.Native` (the C entry points), the native support modules (`ElmLean.Native.*`) | Trusted, tested | `selftest`; `protocol_test.py`, itself validated against `framework/scripts/fake_cli.py`, an independent implementation of the protocol |
| The shell's agreement with the UI grammar (node decoding, dispatch, enums, events) | Checked as it builds | `ElmShell/Check.lean`: the kernel and the build evaluate every row against `Wire.toJson` and `Event.fromJson?` |
| The shell itself (renderer, store, capabilities, C shim) and the retargeted libraries | Trusted, driven in the simulator | the apps' UI tests |
| An app's `perform` | the app's | that app's own tests |
| Lean's compiler and runtime, UIKit, iOS, and macOS | Trusted | — |

## Repository layout

```
README.md, PROTOCOL.md      this file; the wire protocol (nodes, events, seq, errors)
Makefile                    check: the framework's checks
docs/ISSUES.md              issues moved from posix4e/elmlean
.github/workflows/
  ios-app.yml               the reusable CI workflow for an app
  check.yml                 this repository's own CI (make check, native-demo for iOS and Mac Catalyst)
framework/
  lean/                     Lake package `elmlean`
    ElmLean/                Html, Wire, Erase, Program, Spec, Cmd (proven core); Json, Cli, CmdCli, Selftest,
                            Native (trusted shell); Gate; Proofs/ and Proofs.lean (the framework's gate);
                            Native/ (optional native support: BackgroundRun, the typed capability clients)
    ElmLeanTest/            the native support modules' tests and fixtures (`make check`)
    ElmShell/               the native shell as Lean data; `lake exe elmshell <dir>` prints its Objective-C
  native/                   README (the shell, capabilities, Mac Catalyst), c/ (the C shim), scripts/
                            (ios_lean_sources.sh, retarget_ar.py, …), ci/ (the workflow's scripts)
  scripts/                  check-axioms.sh, protocol_test.py, fake_cli.py
  Makefile                  the framework's own checks
examples/
  native-demo/              every capability in one app, no Swift
```

Until 2026-10-28 the framework also had a generated mode: `elmgen` printed a SwiftUI app from the proven
definitions, held to the Lean CLI by lockstep tests and an independent LCNF translator, with the Todo,
Counter and Send examples. Native mode runs the proven definitions themselves, so that machinery was
removed; the tag `generated-mode` is its last commit.

## Notes

* A toggle event's `value` is authoritative: the app sets a flag, it does not flip one, so a retried
  toggle is harmless.
* `seq` and path elements are checked by value: `1.0` and `1e0` are accepted, `1.5` is `bad-json`.
  Literals with huge exponents or millions of digits are a known limit of Lean's JSON parser
  (PROTOCOL.md, "Shell limits").
* `lake` says "no default toolchain": run it inside a package (the toolchain is pinned there).
* A CLI appears to hang under the harness: it must print nothing but protocol lines on stdout; use
  `IO.eprintln` for diagnostics.
