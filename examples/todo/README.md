# Todo — the main ElmLean example

A todo list: a draft field with Add, one row per todo (toggle, Delete), an All/Active/Done
filter, a "n left" caption and Clear done. It is an ordinary Lean package that requires the
framework (`lakefile.toml`), and it exercises everything the framework offers: a `Spec`, a
theorem table about its view and its messages, a scripted self-test, the generated native app,
the generator's corpus, and the bridge end to end.

```
Todo/Model.lean, Update.lean, View.lean, App.lean   the app (`Todo.app`)
Todo/Proofs/Update.lean, View.lean, Session.lean     the theorems; `Todo.spec : Spec app`
Todo/Selftest.lean                                   the scripted self-test run by `todo-cli selftest`
Todo/Gate.lean                                       the axiom gate (imported by the root module `Todo`)
Main.lean                                            `ElmLean.Cli.main Todo.app args Todo.Selftest.options`
ElmGenTests/Negative.lean                            elmgen's corpus, using this model as its fixture
generated/                                           elmgen's output, checked in and golden-tested
ios/                                                 the generated native app (xcodegen project + App shell)
```

## Run it

```bash
make check      # gate · selftest · protocol harness · golden · generated CLI + lockstep · cross-check · corpus · bridge
```

```bash
make ios        # the generated native app in the iPhone simulator
```

```bash
make serve      # the Lean CLI behind the bridge; then framework/viewer-ios/scripts/sim.sh all for the viewer
```

Try the CLI directly:

```bash
printf '%s\n' '{"seq":0,"path":[1,0],"event":{"k":"input","value":"Milk"}}' '{"seq":1,"path":[1,0],"event":{"k":"submit"}}' | .lake/build/bin/todo-cli
```

## What is proven

`Todo/Gate.lean` asserts each theorem below and scans every theorem under `ElmLean` and `Todo`.

| Theorem (namespace `Todo`) | Plain-language guarantee |
|---|---|
| `init_inv`, `update_inv` | The invariant (ids pairwise distinct, every id below `nextId`, no empty title) holds initially and is preserved by every message. |
| `todo_start_inv`, `todo_handle_inv`, `todo_run_inv` | …and therefore after every possible sequence of requests to the real app (`todo_run_inv` is `spec.reachable_inv`). |
| `countToggles_view`, `toggleLabels_view` | The emitted tree has exactly one toggle per visible todo, labelled by the visible titles, in order. |
| `delete_dispatch`, `toggle_dispatch` | Row `i`'s Delete dispatches to `delete` of exactly the `i`-th visible todo's id; row `i`'s toggle dispatches to `setDone` of that id with the value the renderer sent. These identify the *message*; the next row says what the message does. |
| `delete_mem_iff`, `delete_length`, `setDone_*` | `delete id` removes exactly the todos with that id (one todo under the invariant); `setDone id b` leaves ids and titles unchanged, sets that todo's flag to `b`, touches no other todo, and is idempotent (`setDone_idem`). |
| `footer_text`, `add_enabled_iff` | The "n left" caption is the real remaining count; Add is clickable iff the trimmed draft is non-empty. |
| `view_sat`, `view_sound` | Every control the view advertises dispatches to a **well-targeted** message: any id it names belongs to an existing todo. |
| `todo_advertised_ok` | Coherent session + matching `seq` + advertised control ⇒ a well-targeted message. |
| `todo_reachable_sound` | For every session the CLI can reach, an in-sync request for any advertised control is answered by running `update` on a well-targeted message (`spec.reachable_sound`). |

## Notes

* The todo view keeps its only field in a fixed header row, so positional paths never move
  the draft to another field.
* Paths for reference: `[0]` title · `[1,0]` field · `[1,1]` Add ·
  `[2,i,{0 toggle, 1 spacer, 2 Delete}]` · `[3]` divider · `[4,{0,1,2}]` filters ·
  `[5]` "n left" · `[6]` Clear done.
