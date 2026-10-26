# ElmLean — Elm-style apps written and proven in Lean 4, running natively on iOS

ElmLean is a framework for writing apps in the Elm architecture (`Model`, `Msg`, `update`,
`view`) in **Lean 4**, proving things about them with Lean's checker, and running them on
iOS. An app is an ordinary Lean package that depends on the framework. You write the app in a
small typed UI language, state what it should guarantee, and prove it. The framework then
gives you two ways to run the very definitions you proved:

```
                         your app: Model · Msg · update · view : Model → Html Msg · theorems
                                                │
              ┌─────────────── served ──────────┴────────── generated ───────────────┐
              ▼                                                                      ▼
  <app>-cli  (Lean binary, ElmLean.Cli.main)                      lake exe elmgen  (Lean metaprogram)
     │ newline-delimited JSON (PROTOCOL.md)                          │ reads the proven definitions
  framework/bridge/bridge.py   GET /view · POST /event               ▼ from the kernel environment
     │ http://127.0.0.1:8787                                  generated/Generated.swift + <App>Screen.swift
  framework/viewer-ios  (generic SwiftUI viewer, any app)           │ + framework/swift (runtime, element kit)
                                                                    ▼
                                                            a native SwiftUI app, no bridge, no Lean at runtime
                                                            (lockstep-tested against <app>-cli on every check)
```

* **Served**: the app's Lean executable owns the model and speaks a small JSON protocol; a
  generic SwiftUI viewer renders whatever tree it sends. Good for development and for apps
  whose logic should stay on a Mac or a server.
* **Generated**: `elmgen` translates the app's `update` and `view` to Swift and prints the view
  as a SwiftUI screen. A differential test checks the generated code step by step against the
  Lean binary, and an independent second translator cross-checks both.

Two complete apps live in `examples/`: [Todo](examples/todo/README.md) (the main example, with
its full theorem table) and [Counter](examples/counter/README.md).

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
subset stops `elmgen` with the construct named. Served-only apps can use all of Lean.

**2. The proofs.** A `Spec app` (`framework/lean/ElmLean/Spec.lean`) is three obligations:

| Field | You prove |
|---|---|
| `init_inv` | your invariant `Inv` holds for the initial model |
| `update_inv` | every message preserves `Inv` |
| `view_sat` | in every model with `Inv`, every handler in the view yields a message satisfying `Target m` (what a sensible message is in model `m`; `fun _ _ => True` plus `Html.Sat.of_forall` when there is nothing to say) |

The framework turns those into guarantees about every session the CLI can ever reach:
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

**4. The executable.** One line in `Main.lean`:

```lean
def main (args : List String) : IO UInt32 := ElmLean.Cli.main Notes.app args
```

`<app>-cli serve` (the default) speaks the protocol on stdin/stdout. `<app>-cli selftest`
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
| `make serve` | the bridge on port 8787, for the generic viewer |

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

| Layer | Status | How it is checked |
|---|---|---|
| `Html`, `Wire`, `toWire`, `dispatch`, `Session.handle`, `Spec`, each app's `update`/`view` | **Proven** | each package's gate |
| JSON codecs, the stdin/stdout loop (`framework/lean/ElmLean/{Json,Cli}.lean`) | Trusted, tested | `selftest`; `protocol_test.py` on every app, validated itself against `framework/scripts/fake_cli.py`, an independent stdlib implementation of the protocol |
| `framework/bridge/bridge.py` | Trusted, tested | `framework/scripts/bridge_unit_test.py`; `bridge_test.sh` end to end on a side port, including CLI kill and restart |
| `framework/viewer-ios` | Trusted, tested | Swift Testing (node decoding and the queued-event rules of `PROTOCOL.md` against a stubbed bridge); driven in the simulator |
| `elmgen` and `framework/swift` | Trusted, tested | loud rejection outside the subset (the corpus in `examples/todo/ElmGenTests`), golden files, lockstep against the Lean CLI, the LCNF cross-check |
| Lean compiler and runtime, Python, Swift, SwiftUI | Trusted | — |

Out of scope on purpose: Elm `Cmd`/`Sub` (effects, subscriptions), running Lean on the
device, persistence (a served app's model lives in its CLI process).

## Repository layout

```
README.md, PROTOCOL.md      this file; the wire contract (nodes, events, seq, errors, HTTP, client rules)
Makefile                    check = framework + examples + template-test; new-app; serve
framework/
  lean/                     Lake package `elmlean`
    ElmLean/                Html, Wire, Erase, Program, Spec (proven core); Json, Cli, Selftest (trusted
                            shell); Gate (the gate commands); Proofs/ and Proofs.lean (the framework's gate)
    ElmGen/                 the Lean → Swift generator (`lake exe elmgen`)
  swift/                    Runtime.swift (Html mirror, JSON, Session loop), Elements.swift (SwiftUI kit, Store)
  viewer-ios/               the generic SwiftUI viewer for served apps (xcodegen project, unit tests, sim.sh)
  bridge/bridge.py          stdlib HTTP ⇄ stdin/stdout bridge
  crosscheck/               the independent LCNF translator
  scripts/                  check-axioms.sh, protocol_test.py, lockstep.py, fake_cli.py, bridge tests,
                            gen_golden_test.sh, gen_crosscheck.sh, app_sim.sh, new_app.sh, template_test.sh
  template/                 what `make new-app` copies
  app.mk, Makefile          the per-app rules; the framework's own checks
examples/
  todo/                     the main example (README with its theorem table)
  counter/                  a second, smaller example
```

## Notes and known limitations

* Paths are positional, so renderer-local state (a field's draft) follows a position. The
  viewer drops a click created against an older view ("view changed; tap again") rather than
  re-target it; closing that window would need node identity on the wire.
* A toggle event's `value` is authoritative: the app sets a flag, it does not flip one, so a
  retried toggle is harmless.
* `seq` and path elements are checked by value: `1.0` and `1e0` are accepted by the CLI,
  `1.5` is `bad-json`. The bridge forwards only JSON integers of at most 4300 digits, which
  keeps out literals that Lean's JSON parser would take very long to read (`PROTOCOL.md`,
  "Shell limits").
* The bridge serializes requests, validates every reply's `seq`, and restarts the CLI if it
  dies, hangs or desynchronises; a restart resets the model (HTTP 502, the viewer reloads).
* `framework/scripts/bridge_test.sh` probes a field at `[1,0]`, so it runs against the Todo
  example and the fake CLI; the harness and lockstep tests are generic.

## Troubleshooting

* `lake` says "no default toolchain": run it inside a package (the toolchain is pinned there).
* `elmgen` says "unsupported …": the named construct is outside the generated subset; rewrite
  it with the constructs listed above, or keep the app served-only.
* Port 8787 busy: `make serve PORT=8790`, then change the viewer's URL in its gear sheet.
* `bridge_test.sh` refuses to run while anything else listens on its side port (8791), and it
  needs `lsof` (from `PATH` or `/usr/sbin/lsof`) to prove the listener is its own bridge.
* A served CLI appears to hang: it must print nothing but protocol lines on stdout; use
  `IO.eprintln` for diagnostics.
* The viewer shows "backend unavailable": the bridge could not start the CLI (`make build`
  first, or check `--cli`); it retries on the next event.
