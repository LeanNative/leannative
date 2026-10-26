# ElmLean wire protocol (v1)

The backend is an app's CLI (for the Todo example `examples/todo/.lake/build/bin/todo-cli`), a
Lean 4 program built on `ElmLean.Cli.main` that owns the Elm architecture (`Model`, `Msg`,
`update`, `view`). It speaks **newline-delimited JSON** over stdin/stdout. The renderer (the
generic SwiftUI viewer, `framework/viewer-ios`) knows only the node and event grammars below,
never the app. The generated native apps and their test CLIs speak the same protocol.

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
    level the same `path` may name another row once the view has changed; the client rules below
    exist to stop that
* Unknown extra keys are ignored. Semantic validation failures (missing `seq`/`path`/`event`,
  non-integer `seq`, negative or non-integer path element, unknown `k`, missing or wrongly
  typed `value`) are reported as `bad-json`, and that check runs before the `stale` check.
* `seq` and every path element must be a JSON **number whose value is a non-negative
  integer**. The rule is about the value, not the spelling: `1`, `1.0`, `1e0` and `10e-1` all
  denote 1 and are accepted; `1.5`, `-1`, `"1"`, `true` and `null` are `bad-json`. The CLI
  normalises by value deliberately: Lean's parser keeps `1` and `1.0` apart (mantissa/exponent
  `⟨1,0⟩` vs `⟨10,1⟩`) and `ElmLean.Json.getNatValue?` accepts a spelling iff `10^exponent`
  divides the mantissa. The HTTP bridge is stricter and accepts only JSON integers, see below.
* **Shell limits** (stdin only; unreachable through the HTTP bridge, which forwards only JSON
  integers of at most 4300 digits): Lean's standard JSON parser materialises `10^N` for a literal
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
| `{"seq":n,"error":"stale","view":<node>}` | request `seq` ≠ current; the included view is the current one and may be adopted directly (a follow-up `GET /view` is optional) | unchanged |
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
An unknown `style` renders as `body` and an unknown `role` as `plain`; an unknown `t` renders
as a visible placeholder.
Strings are UTF-8; `"`, `\` and control characters are JSON-escaped, so a node
never contains a raw newline. Renderers must render an unknown `t` as a visible
placeholder rather than fail.

## What a renderer may send ("advertised" controls)

A control is *advertised* when the node at `path` accepts the event kind:

| node | accepted events |
|---|---|
| `button` with `"enabled":true` | `click` |
| `field` | `input`; and `submit` iff `"submits":true` |
| `toggle` | `toggle` |
| anything else | none |

**Guarantee (machine-checked in Lean, `ElmLean.Html.advertises_iff`):** for the
view the CLI emitted, a `(path, event)` pair is advertised **iff** dispatching it
yields a message. So a renderer that only fires advertised controls with the right
`seq` never receives `bad-path` or `no-handler`.

## HTTP bridge (`framework/bridge/bridge.py`, default `http://127.0.0.1:8787`)

| HTTP | body | when |
|---|---|---|
| `GET /view` → 200 | `{"seq":n,"view":…}` | current view (no CLI round trip) |
| `POST /event` → 200 | `{"seq":n+1,"view":…}` | success |
| `POST /event` → 409 | `{"seq":n,"error":"stale","view":…}` | stale |
| `POST /event` → 400 | `{"seq":n,"error":"bad-path"\|"no-handler"\|"bad-json",…}` from the CLI, or the bridge's own `{"error":"bad-request"}` (no `seq`) when the body is not JSON, `seq` or a path element is not an integer, `path` not a list, `event` not an object, or the request target itself cannot be parsed (NUL byte, malformed absolute-form URL) | rejected; clients treat `seq` as optional here |
| `POST /event` → 502 | `{"error":"cli-restarted","seq":0}` | the CLI died or hung and was restarted with a fresh model; the client must `GET /view` (or adopt the next `/view`) and discard **all** pending events, inputs included |
| `POST /event` → 503 | `{"error":"cli-unavailable","detail":"<free text>"}` | the CLI died and could not be restarted (binary missing, exited before its first line, first line not a seq-0 view, no initial view within 5 s); `GET /view` keeps serving the last known view and never touches the CLI; the client keeps its view, shows a notice and retries later. The bridge attempts a fresh start on every later `POST /event`; when one succeeds the CLI has a fresh model, so that POST is answered 502 and pending events, parked inputs included, are discarded as after any restart |
| any other path → 404 | `{"error":"not-found"}` | the bridge serves no static files |

All responses carry `Cache-Control: no-store`. The POST body is the client→CLI
object above; `reset` is not exposed over HTTP. The bridge forwards exactly `seq`, `path`
and `event`; it requires `seq` and every path element to be JSON integers (Python `int`, at
most 4300 digits, Python's default), `path` a list and `event` an object, answering
`400 {"error":"bad-request"}` otherwise without consulting the CLI. The bridge also checks every CLI reply: a `view` reply must carry
`seq` = current + 1 and an error reply `seq` = current; anything else is treated as a
desynchronised CLI, which is restarted (→ 502).

## Client rules for queued events (renderers)

A renderer may queue several events before the first reply arrives (a typing burst, type then
Return, two quick taps). Because `path` is positional and `seq` names the view the user acted
on, every queued event records the `seq` of the view it was **created against**, and the
renderer applies these rules when an event reaches the head of the queue (and again to the
in-flight event and the whole queue after a 409):

| event | created against the current `seq` | created against an older view |
|---|---|---|
| `click`, `toggle` | send | **drop locally**, show a short notice ("view changed; tap again"); never re-target, there is no node identity on the wire |
| `input` | send | re-stamp with the current `seq` **iff** the node at `path` in the current view is still a `field`; else drop (and tell the field, so its draft is reconciled) |
| `submit` | send | re-stamp **iff** the node at `path` is a `field` with `"submits":true`; else drop |

* On **409** the client adopts the `view`/`seq` from the 409 body (no extra `GET /view` is
  needed), then applies the table to the in-flight event and the queue. After three
  consecutive 409s it drops everything and resyncs. *Consecutive* means within one drain of
  the queue: the counter resets when the renderer is idle after pumping its queue (nothing in
  flight, queue empty), on any non-409 `/event` reply and when inputs are parked, so two taps
  dropped minutes apart cannot cost an unrelated draft. The cap notice reports the number of
  events the cap itself discarded, i.e. those the table would have kept; an event the table drops
  anyway gets its own "tap again" notice, and coalescing inputs is not a discard.
* On **502** it drops every pending event (inputs included) and adopts the fresh view.
* On **503** or a transport failure it keeps the view, parks pending `input`s (latest value per
  path), drops other events, shows a notice, and re-queues the parked inputs after the next
  successful `GET /view` (the table above then decides whether they still apply). Retries back
  off from 1 s to a cap of 8 s between consecutive failures. The delay resets when the backend
  answers `/event` with anything but 503, when a view with a **new** `seq` is adopted, or when
  the renderer is idle with nothing parked; a cached `GET /view` 200 during an outage does not
  reset it (the bridge keeps serving the last view), so a renderer with parked inputs really
  backs off instead of re-posting every second.
* Two kinds of sticky notice. "cannot reach the bridge" (transport failure: no HTTP reply, or a
  body that is not JSON, on either endpoint) clears on any readable reply from the bridge.
  "backend unavailable" (503, or an `/event` reply that is JSON but neither a view nor a known
  error) clears only on the next `/event` reply of any status, because `GET /view` is served from
  the bridge's cache and a 200 from it proves nothing about the CLI. Both may be set at once;
  "backend unavailable" is shown first. A notice must not claim to be retrying while the
  renderer is idle (nothing queued, no timer pending).
* The same rules drop a tap made while this client's **own** earlier request is still in
  flight, since its reply advances `seq`: typing and then tapping Add before the last keystroke
  was acknowledged shows "view changed; tap again" (Return is unaffected, `submit` is
  re-stamped). Renderers coalesce unsent `input`s per path (latest value wins), merging only
  into the tail of the queue: never into the in-flight event and never across a `submit`,
  `click` or `toggle`, which read the field in order. That keeps the window one round trip wide;
  closing it entirely would need node identity on the wire, which v1 does not have.
* A field shows what the user typed until the server has acknowledged it; only when an input
  is genuinely dropped (502, stale cap, path no longer a field) does the field fall back to the
  server's value.
* Exactly one request is in flight at a time, lifecycle `GET /view`s included (page shown
  again, app became active), and it stays "in flight" until any resync it triggers has
  completed.
