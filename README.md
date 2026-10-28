# ElmLean — Elm-style apps written and proven in Lean 4, running natively on iOS and Mac

ElmLean is a framework for writing apps in the Elm architecture (`Model`, `Msg`, `update`,
`view`) in **Lean 4**, proving things about them with Lean's checker, and running the very same
definitions on iOS and Mac. An app is an ordinary Lean package that depends on the framework. Lean's
compiler turns it into C, which is linked into the iOS app with Lean's runtime; a generic shell draws
the view tree the app returns with UIKit and does what only iOS can do. No Swift is compiled, and none
is written per app.

```
        your app: Model · Msg · update · view : Model → Html Msg · cmds · perform · theorems
                                    │
                     lake build ──► the app and ElmLean as C (.lake/build/ir)
                                    │
     framework/native/scripts/ios_lean_sources.sh: the C of the app's import closure, Lean's runtime
                                    │  retargeted to iOS, and the shell's Objective-C printed from Lean
                                    ▼                  (`lake exe elmshell`, checked against the grammar)
                    Xcode (project.yml): one iOS / Mac Catalyst app, no Swift
```

Winnow, a Bitcoin wallet, is the app this is built for
([winnowwallet/winnow-lean](https://github.com/winnowwallet/winnow-lean)); `examples/native-demo` is a
small complete app that exercises every capability.

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

The shell answers user events exactly as `Session.step` does, so these theorems are about the code that
runs on the phone, not about a translation of it.

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

## Building an app for iOS

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

## Continuous integration for an app

`.github/workflows/ios-app.yml` is a reusable workflow that builds and tests an ElmLean app on GitHub
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
    uses: posix4e/elmlean/.github/workflows/ios-app.yml@<commit>
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
| `Html`, `Wire`, `toWire`, `dispatch`, `Session`, `Spec`, `CmdSpec`, each app's `update`/`view`/`cmds` | **Proven** | each package's gate |
| JSON codecs, the CLI loop, `ElmLean.Native` (the C entry points) | Trusted, tested | `selftest`; `protocol_test.py`, itself validated against `framework/scripts/fake_cli.py`, an independent implementation of the protocol |
| The shell's agreement with the grammar (node decoding, dispatch, enums, events, capabilities) | Checked as it builds | `ElmShell/Check.lean`: the kernel and the build evaluate every row against `Wire.toJson` and `Event.fromJson?` |
| The shell itself (renderer, store, capabilities, C shim) and the retargeted libraries | Trusted, driven in the simulator | the apps' UI tests |
| An app's `perform` | the app's | that app's own tests |
| Lean's compiler and runtime, UIKit and iOS | Trusted | — |

## Repository layout

```
README.md, PROTOCOL.md      this file; the wire protocol (nodes, events, seq, errors)
Makefile                    check: the framework's checks
.github/workflows/
  ios-app.yml               the reusable CI workflow for an app
framework/
  lean/                     Lake package `elmlean`
    ElmLean/                Html, Wire, Erase, Program, Spec, Cmd (proven core); Json, Cli, CmdCli, Selftest,
                            Native (trusted shell); Gate; Proofs/ and Proofs.lean (the framework's gate)
    ElmShell/               the native shell as Lean data; `lake exe elmshell <dir>` prints its Objective-C
  native/                   README (the shell, capabilities, Mac Catalyst), c/ (the C shim), scripts/
                            (ios_lean_sources.sh, retarget_ar.py, …), ci/ (the workflow's scripts)
  scripts/                  check-axioms.sh, protocol_test.py, fake_cli.py
  Makefile                  the framework's own checks
examples/
  native-demo/              every capability in one app, no Swift
```

Until 2026-10-28 ElmLean also had a generated mode: `elmgen` printed a SwiftUI app from the proven
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
