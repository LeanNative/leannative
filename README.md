# ElmLean — Elm-style apps written and proven in Lean 4, running natively on iOS

ElmLean is a framework for writing apps in the Elm architecture (`Model`, `Msg`, `update`,
`view`) in **Lean 4**, proving things about them with Lean's checker, and running them on
iOS. An app is an ordinary Lean package that depends on the framework. You write the app in a
small typed UI language, state what it should guarantee, and prove it. The framework then
generates a native SwiftUI app from the very definitions you proved: no bridge, no server and no
Lean at runtime.

```
        your app: Model · Msg · update · view : Model → Html Msg · theorems
                                    │
                     lake exe elmgen  (Lean metaprogram: reads the proven
                                    │  definitions from the kernel environment)
                                    ▼
          generated/Generated.swift + <App>Screen.swift + framework/swift
                                    │
                                    ▼
                         a native SwiftUI app on iOS

   tested against:  <app>-cli, the same definitions compiled by Lean, as the reference.
                    The generated update/view, compiled as a macOS CLI, must give identical
                    replies step by step (lockstep), and an independent second translator
                    (LCNF) is locked in step with both.
```

The app's Lean executable is a test oracle, not a runtime: it speaks a small JSON protocol on
stdin/stdout ([PROTOCOL.md](PROTOCOL.md)) so the generated code can be checked against it.

Three complete apps live in `examples/`: [Todo](examples/todo/README.md) (the main example, with
its full theorem table), [Counter](examples/counter/README.md), and [Send](examples/send/README.md),
Winnow's Send review flow with commands run against Winnow's WalletCore, proven to sign only what
the user approved on screen and to broadcast only a transaction that matches it.

## Quick start

```bash
make new-app NAME=Notes          # scaffold apps/notes from framework/template
```

```bash
cd apps/notes && make gen && make check
```

```bash
make ios                         # from apps/notes: the generated native app in the iPhone simulator
```

The Send example builds its host against a checkout of Winnow (`WINNOW`, default
`~/src/winnow-claude`), so `make send` and the full root `make check` need one; `make framework todo
counter template-test` do not.

`make gen` writes the Swift files, `make check` runs every gate of the app (below), and the
scaffolded app passes them out of the box: `make template-test` at the root proves that on
each run. Prerequisites on a Mac with Xcode: `elan` (the toolchain `leanprover/lean4:v4.35.0` is
pinned per package by `lean-toolchain`; no default toolchain needed), Homebrew Python 3, and
`xcodegen` for the iOS projects.

## Writing an app

**1. The app.** `Html msg` is the UI language (`framework/lean/ElmLean/Html.lean`):

```lean
inductive Html (msg : Type) where
  | text   (s : String) (style : TextStyle)                                  -- title | body | caption
  | col    (children : List (Html msg))
  | row    (children : List (Html msg))
  | button (label : String) (role : ButtonRole) (onClick : Option msg)        -- none ⇒ disabled
  | field  (placeholder value : String) (onInput : String → msg) (onSubmit : Option msg)
  | toggle (label : String) (on : Bool) (onToggle : Bool → msg)
  | divider
  | spacer
```

Because `view : Model → Html Msg` is typed, a view can only emit messages that `update`
handles: Elm's core guarantee, from the type checker. The app value is
`def app : App Model Msg := ⟨Model.init, update, view⟩` in the app's namespace.

To be generated as Swift, the app must stay inside the subset `elmgen` translates: structures,
inductives with payloads, `List`/`String`/`Nat`/`Bool`/`Option`, `match` and `if` on app types,
`List.map`/`filter`/`length`/`any`/`++`, string interpolation, `s.trimAscii.copy`, the `Html`
constructors, and named helpers in the app's namespace. Recursion, `where`, `dite`, patterns
on `Nat` or nested structures, and equality on types with `String` fields are rejected by design;
`Nat` subtraction is saturating in Lean and is printed as `max(a - b, 0)`. Anything outside the
subset stops `elmgen` with the construct named.

**2. The proofs.** A `Spec app` (`framework/lean/ElmLean/Spec.lean`) is three obligations:

| Field | You prove |
|---|---|
| `init_inv` | your invariant `Inv` holds for the initial model |
| `update_inv` | every message preserves `Inv` |
| `view_sat` | in every model with `Inv`, every handler in the view yields a message satisfying `Target m` (what a sensible message is in model `m`; `fun _ _ => True` plus `Html.Sat.of_forall` when there is nothing to say) |

The framework turns those into guarantees about every session of the app's protocol state
machine (`Session.handle`, the step the CLI runs and the generated code is tested against):
`spec.reachable_inv rs` (the invariant holds after any request trace `rs`) and
`spec.reachable_sound` (an in-sync request for any advertised control dispatches to a message
satisfying `Target`, and the CLI answers it by running `update` on exactly that message). Add
any app-specific theorems next to them.

**3. The gate.** A gate file lists the theorems you advertise and scans the rest:

```lean
import ElmLean.Gate
import Notes.Proofs
#assert_axioms Notes.update_inv
#assert_all_axioms ElmLean Notes
```

`#assert_axioms` fails the build if a theorem depends on anything beyond `propext`,
`Quot.sound` and `Classical.choice`, so a `sorry` cannot hide. `#assert_all_axioms` applies the
same check to every theorem under the given namespaces, framework theorems included.
`framework/scripts/check-axioms.sh` also greps the build log for `sorry` warnings in
definitions. `framework/lean/ElmLean/Gate.lean` spells out what each layer covers.

**Commands.** An app that needs its host to do things (call a wallet, authenticate, broadcast) is a
`CmdApp Model Msg Cmd Host` (`framework/lean/ElmLean/Cmd.lean`): an `App` plus
`cmds : Msg → Model → List Cmd`, the commands a message asks for in the same pre-state `update` sees,
and `host : Host → Msg`, the only way a host answer enters the app. This departs from Elm's
`update : Msg → Model → (Model, Cmd Msg)` on purpose: two functions of the same arguments stay
inside the subset `elmgen` translates. `Cmd` and `Host` are ordinary app types (derive
`Lean.ToJson`/`Lean.FromJson`); `elmgen` prints their JSON codecs, and the generated app runs each
command on a hand-written `CmdHost` (`Store.attach`). `CmdSpec` is the `Spec` of such an app, and
`CmdSpec.trace_origin` says where every message of every run comes from: an in-sync control of the
view the client was shown, or `app.host h`. The host is trusted; what the app does with its
answers is proven (see the Send example).

**4. The executable.** One line in `Main.lean`:

```lean
def main (args : List String) : IO UInt32 := ElmLean.Cli.main Notes.app args
```

(`ElmLean.CmdCli.main` for an app with commands; set `CLI_RUNNER := runCmdElmCli` in its Makefile.)

`<app>-cli serve` (the default) speaks the protocol on stdin/stdout; the lockstep and harness
tests drive it. `<app>-cli selftest`
explores the app breadth-first from its initial model. It fires every advertised control
(2000 steps by default) and re-checks at runtime what the theorems state: replies at `seq + 1`,
coherence, "advertised iff dispatchable", stale rejection, and JSON round trips. A fourth
argument `{ check := …, script := … }` adds your invariant's runtime mirror and a scripted run
(see `examples/todo/Todo/Selftest.lean`).

**5. The Makefile.** An app's Makefile sets a few variables and includes `framework/app.mk`:

| Target | What it runs |
|---|---|
| `make build` | `lake build`: the app, its proofs, its gate, its CLI |
| `make axioms` | the gate with its log checks |
| `make selftest` | the CLI's exploration and the app's script |
| `make protocol` | `framework/scripts/protocol_test.py` against the CLI: converse cases, number spellings, a 300-step random walk, an exhaustive replay |
| `make gen` | regenerate `generated/` with `elmgen` |
| `make golden` | the checked-in generated files are byte-identical to a fresh `elmgen` run |
| `make gen-test` | the generated Swift compiled as a macOS CLI: the protocol harness, then `lockstep.py` against the Lean CLI (identical replies on 800 steps) |
| `make crosscheck` | the independent LCNF translation, locked in step with both |
| `make check` | all of the above |
| `make ios` | xcodegen, build, install and launch the generated app in the simulator |

## What the framework proves, and what it trusts

The framework's gate (`framework/lean/ElmLean/Proofs.lean`) holds the theorems every app relies on:

| Theorem (namespace `ElmLean`) | Guarantee, for any app |
|---|---|
| `Html.advertises_iff` | A `(path, event)` pair is advertised by the wire tree **iff** dispatching it on the real view yields a message. Nothing un-advertised can trigger anything. |
| `Html.Sat.dispatch`, `Html.Sat.of_forall` | If every handler satisfies a predicate, so does every dispatched message; a predicate true of all messages holds of every tree. |
| `Session.handle_advertised`, `Session.handle_dispatch` | An in-sync advertised request is answered with a new view at `seq + 1`, by running `update` on the dispatched message. |
| `Session.start_coherent`, `Session.handle_coherent`, `Session.run_coherent`, `Session.reach_coherent` | The protocol state machine always shows the view of its current model. |
| `Session.handle_inv`, `Session.run_inv` | Any invariant preserved by `update` holds after any request trace. |
| `Spec.reachable_inv`, `Spec.reachable_sound` | What a `Spec` buys: the invariant and well-targeted dispatch in every reachable session. |
| `Session.step_origin`, `CmdSpec.reachable_inv`, `CmdSpec.trace_origin` | Apps with commands: every step runs `update` on at most one message and asks for exactly `cmds` of it, and that message is an in-sync dispatch from the view shown or a host answer through `app.host`, along any interleaving of events and answers. |

| Layer | Status | How it is checked |
|---|---|---|
| `Html`, `Wire`, `toWire`, `dispatch`, `Session.handle`, `Spec`, each app's `update`/`view` | **Proven** | each package's gate |
| JSON codecs, the stdin/stdout loop (`framework/lean/ElmLean/{Json,Cli}.lean`) | Trusted, tested | `selftest`; `protocol_test.py` on every app, validated itself against `framework/scripts/fake_cli.py`, an independent stdlib implementation of the protocol |
| `elmgen` and `framework/swift` | Trusted, tested | loud rejection outside the subset (the corpus in `examples/todo/ElmGenTests`), golden files, lockstep against the Lean CLI, the LCNF cross-check |
| SwiftUI binding of the generated screen (`framework/swift/Elements.swift`) | Trusted, driven in the simulator | `make ios` |
| An app's command host (the Send example's WalletCore host) | Trusted, tested | that app's own tests (`make host-test` in examples/send) |
| Lean compiler and runtime, Python, Swift, SwiftUI | Trusted | — |

Out of scope on purpose: Elm `Sub` (subscriptions; a host may instead send answers at any time),
running Lean on the device, persistence.

## Repository layout

```
README.md, PROTOCOL.md      this file; the oracle protocol (nodes, events, seq, errors)
Makefile                    check = framework + examples + template-test; new-app
framework/
  lean/                     Lake package `elmlean`
    ElmLean/                Html, Wire, Erase, Program, Spec, Cmd (proven core); Json, Cli, CmdCli, Selftest
                            (trusted shell); Gate (the gate commands); Proofs/ and Proofs.lean (the framework's gate)
    ElmGen/                 the Lean → Swift generator (`lake exe elmgen`)
    ElmShell/               native mode's shell as Lean data; `lake exe elmshell <dir>` prints its Swift
  swift/                    Runtime.swift (Html mirror, JSON, Session loop), Elements.swift (SwiftUI kit, Store)
  crosscheck/               the independent LCNF translator
  scripts/                  check-axioms.sh, protocol_test.py, lockstep.py, fake_cli.py,
                            gen_golden_test.sh, gen_crosscheck.sh, app_sim.sh, new_app.sh, template_test.sh
  template/                 what `make new-app` copies
  app.mk, Makefile          the per-app rules; the framework's own checks
examples/
  todo/                     the main example (README with its theorem table)
  counter/                  a second, smaller example
  send/                     Winnow's Send review flow: an app with commands and a WalletCore host
```

## Notes and known limitations

* In the generated app a control hands its message straight to `update` (`Store.send` in
  `framework/swift/Elements.swift`), as in Elm. Paths and `seq` exist only in the protocol the
  CLI and the tests speak, where they make each step a pure function the theorems cover.
* A toggle event's `value` is authoritative: the app sets a flag, it does not flip one, so a
  retried toggle is harmless.
* `seq` and path elements are checked by value: `1.0` and `1e0` are accepted by the CLI,
  `1.5` is `bad-json`. Literals with huge exponents or millions of digits are a known limit
  of Lean's JSON parser (`PROTOCOL.md`, "Shell limits").

## Troubleshooting

* `lake` says "no default toolchain": run it inside a package (the toolchain is pinned there).
* `elmgen` says "unsupported …": the named construct is outside the generated subset; rewrite
  it with the constructs listed above.
* A CLI appears to hang under the harness: it must print nothing but protocol lines on stdout;
  use `IO.eprintln` for diagnostics.
