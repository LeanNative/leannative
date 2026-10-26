# ElmLean wire protocol (v1)

The backend is an app's CLI (for the Todo example `examples/todo/.lake/build/bin/todo-cli`), a
Lean 4 program built on `ElmLean.Cli.main` that owns the Elm architecture (`Model`, `Msg`,
`update`, `view`). It speaks **newline-delimited JSON** over stdin/stdout. It is the reference
the generated code is tested against, not a runtime: an app's generated `update`/`view`,
compiled as a macOS CLI over `framework/swift/Runtime.swift`, speaks the same protocol, and
`framework/scripts/lockstep.py` requires both CLIs to give the same replies to the same lines.
The generated iOS app itself calls `update` directly and never speaks this protocol.

## Transport rules

* One JSON object per line, both directions. `stdout` carries protocol lines only;
  diagnostics go to `stderr`. The CLI flushes after every line.
* On start the CLI prints exactly one line: `{"seq":0,"view":<node>}`.
* For **every** input line (including blank or malformed ones) the CLI prints
  exactly one reply line (one stdin-only exception: see "Shell limits" below). At EOF it exits 0.
* `seq` is the sequence number of the view the client rendered. The CLI dispatches
  a request against the **last view it emitted**; a request whose `seq` does not
  match is rejected as `stale`. `seq` advances only on a successful event (or `reset`).
* The CLI is deterministic: the same input lines always produce the same output lines.

## Client → CLI

```json
{"seq": 3, "path": [2, 0, 2], "event": {"k": "click"}}
```

* `path` — list of child indices from the root (`[]` is the root). Only `col` and
  `row` have children (their `c` arrays).
* `event` — one of
  * `{"k":"click"}` — buttons
  * `{"k":"input","value":"<full current text>"}` — fields (full value, not a delta)
  * `{"k":"submit"}` — fields with `"submits":true` (return key)
  * `{"k":"toggle","value":true|false}` — toggles; `value` is the control's new state and is
    authoritative (the app sets the flag to `value`, it does not flip), so two identical toggle
    *messages* for the same todo are idempotent (Lean: `Todo.setDone_idem` in the Todo example). At the wire
    level the same `path` may name another row once the view has changed, which the `seq`
    guard rejects as `stale`
* Unknown extra keys are ignored. Semantic validation failures (missing `seq`/`path`/`event`,
  non-integer `seq`, negative or non-integer path element, unknown `k`, missing or wrongly
  typed `value`) are reported as `bad-json`, and that check runs before the `stale` check.
* `seq` and every path element must be a JSON **number whose value is a non-negative
  integer**. The rule is about the value, not the spelling: `1`, `1.0`, `1e0` and `10e-1` all
  denote 1 and are accepted; `1.5`, `-1`, `"1"`, `true` and `null` are `bad-json`. The CLI
  normalises by value deliberately: Lean's parser keeps `1` and `1.0` apart (mantissa/exponent
  `⟨1,0⟩` vs `⟨10,1⟩`) and `ElmLean.Json.getNatValue?` accepts a spelling iff `10^exponent`
  divides the mantissa.
* **Shell limits**: Lean's standard JSON parser materialises `10^N` for a literal
  with exponent `N` before the CLI ever sees the value, so a literal with an astronomically large
  exponent (around `1e1000000000000000000`) aborts the process without a reply, and a literal
  with a million digits takes tens of seconds to parse. `framework/scripts/fake_cli.py` answers `bad-json`
  or `stale` on such lines instead; this is the one place where the two CLIs are allowed to differ.
* Shell-only test command: `{"reset":true}` → restores the initial model and replies
  `{"seq":<n+1>,"view":<init view>}`; any other keys in that line are ignored.
  Determinism is about payloads: the same input lines always yield the same `view` payloads
  and error codes, while `seq` numbers depend on how many successful steps preceded them.

## CLI → client

| reply | meaning | `seq` |
|---|---|---|
| `{"seq":n+1,"view":<node>}` | event applied, new view | advanced |
| `{"seq":n,"error":"stale","view":<node>}` | request `seq` ≠ current; the included view is the current one and may be adopted directly | unchanged |
| `{"seq":n,"error":"bad-path"}` | no node at `path` | unchanged |
| `{"seq":n,"error":"no-handler"}` | node exists but does not accept that event kind (disabled button, non-submitting field, click on text, …) | unchanged |
| `{"seq":n,"error":"bad-json","detail":"…"}` | line is not a valid request | unchanged |

Error precedence: `bad-json` > `stale` > `bad-path` > `no-handler`.

## Node grammar (the UI language on the wire)

| node | JSON |
|---|---|
| text | `{"t":"text","s":"…","style":"title"\|"body"\|"caption"}` |
| column | `{"t":"col","c":[…]}` |
| row | `{"t":"row","c":[…]}` |
| button | `{"t":"button","label":"…","role":"plain"\|"primary"\|"destructive","enabled":true\|false}` |
| field | `{"t":"field","placeholder":"…","value":"…","submits":true\|false}` |
| toggle | `{"t":"toggle","label":"…","on":true\|false}` |
| divider | `{"t":"divider"}` |
| spacer | `{"t":"spacer"}` |

Key order within an object is unspecified (the CLI emits keys alphabetically).
Strings are UTF-8; `"`, `\` and control characters are JSON-escaped, so a node
never contains a raw newline.

## What a client may send ("advertised" controls)

A control is *advertised* when the node at `path` accepts the event kind:

| node | accepted events |
|---|---|
| `button` with `"enabled":true` | `click` |
| `field` | `input`; and `submit` iff `"submits":true` |
| `toggle` | `toggle` |
| anything else | none |

**Guarantee (machine-checked in Lean, `ElmLean.Html.advertises_iff`):** for the
view the CLI emitted, a `(path, event)` pair is advertised **iff** dispatching it
yields a message. So a client that only fires advertised controls with the right
`seq` never receives `bad-path` or `no-handler`.
