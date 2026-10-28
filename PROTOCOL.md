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
| text | `{"t":"text","s":"…","style":"title"\|"body"\|"caption"}` (native mode adds `"largeTitle"`, `"title3"`, `"headline"`, `"subheadline"`, `"callout"`, `"footnote"`, `"caption2"`) |
| column | `{"t":"col","c":[…]}` |
| row | `{"t":"row","c":[…]}` |
| button | `{"t":"button","label":"…","role":"plain"\|"primary"\|"destructive","enabled":true\|false}` (native mode adds the roles `"secondary"` and `"cancel"`) |
| field | `{"t":"field","placeholder":"…","value":"…","submits":true\|false}` |
| toggle | `{"t":"toggle","label":"…","on":true\|false}` |
| divider | `{"t":"divider"}` |
| spacer | `{"t":"spacer"}` |

Native mode (framework/native/README.md) adds these nodes; `elmgen` does not translate them:

| node | JSON | children (`c`) | accepted events |
|---|---|---|---|
| input | `{"t":"input","kind":"plain"\|"secure"\|"multiline"\|"number"\|"decimal","label","placeholder","value","submits"}` | — | `input`; `submit` iff `submits` |
| list | `{"t":"list","c":[…]}` | yes | — |
| section | `{"t":"section","header","footer","c":[…]}` | yes | — |
| labeled | `{"t":"labeled","label","value"}` | — | — |
| screen | `{"t":"screen","title","back":bool,"refreshable":bool,"largeTitle":bool,"depth":n,"c":[…]}` (`largeTitle`, default true: a large title that collapses as the page scrolls; `depth`: its place in its navigation stack, 0 the root, at least 1 with `back`: a deeper screen is pushed, a shallower one pops back to it, and the system back button or an edge swipe pops and sends `dismiss`) | yes | `dismiss` iff `back`; `click` iff `refreshable` (pull to refresh) |
| toolbar | `{"t":"toolbar","placement":"trailing"\|"leading"\|"cancel"\|"confirm"\|"bottom","c":[…]}` (in a screen or a sheet: its buttons in the navigation bar's trailing or leading end, `cancel` leading (a `cancel`-role button there is the system Close button, labelled with its label), `confirm` trailing and prominent, `bottom` the toolbar under the page) | yes | — |
| tabs | `{"t":"tabs","labels":[…],"icons":[…],"selected":n,"c":[…]}` | yes (the selected tab's content) | `select` |
| sheet | `{"t":"sheet","title","dismissable":bool,"largeTitle":bool,"size":"large"\|"medium","c":[…]}` (`largeTitle`, default false; `medium` opens at half height with a grabber) | yes | `dismiss` iff `dismissable` |
| alert | `{"t":"alert","title","message","style":"alert"\|"actionSheet","c":[buttons]}` (a `cancel`-role button is the Cancel action, a `primary` one the preferred action; `actionSheet` is a confirmation dialog anchored to the control last used) | yes | — |
| picker | `{"t":"picker","label","options":[…],"selected":n}` | — | `select` |
| progress | `{"t":"progress","label"}` | — | — |
| icon | `{"t":"icon","name"}` (an SF Symbols name) | — | — |
| qr | `{"t":"qr","text"}` | — | — |
| share | `{"t":"share","label","text","file"}` (`file`: `text` is a file path, shared as the file) | — | — |
| link | `{"t":"link","label","url"}` | — | — |
| page | `{"t":"page","path"}` (a bundled HTML file) | — | — |
| empty | `{"t":"empty","title","icon","message","c":[actions]}` | yes | — |
| disclosure | `{"t":"disclosure","title","expanded":bool,"c":[…]}` | yes | `toggle` |
| stepper | `{"t":"stepper","label","value":n,"lo":n,"hi":n,"detail"}` (`detail` "" = show the number) | — | `select` |

Any node may also carry `"id":"…"` (`Html.identified id child`, native mode): an identifier for UI tests,
which the shell sets as the node's `accessibilityIdentifier` (on its control, else its label, else its
image). It is not a node of its own: the object is `child`'s, with `child`'s children and events, so
paths and events pass through it.

Any node may also carry `"decor":{"tone","mono","badge","centered","symbol","chevron"}` (`Html.decorated d child`, native mode):
how it is drawn beyond its kind. `tone` is `"standard"` (the node's own colour), `"secondary"`, `"tint"`,
`"positive"` (green), `"negative"` (red) or `"warning"` (orange); `mono` is monospaced text wrapped at any
character; `badge` draws a text as a capsule in its tone; `centered` centres a text; `symbol` is an SF Symbols name drawn before a button's, a labeled row's or a text's
label; `chevron` marks a button that opens something (a link: in a list its whole row is the button, with a
disclosure chevron). Every field's default
(`"standard"`, `false`) changes nothing, and a shell decodes an absent `decor` or field as its default, so
old and new trees and shells read each other. Like `id` it is not a node: the object, children and events
are `child`'s. `Html.decor` merges decorations, so `(body s).tone .positive |>.mono` is one `decor`.

Events added with them: `{"k":"select","value":n}` (a tab, a picker option, a stepper value) and
`{"k":"dismiss"}` (back from a screen, a sheet swiped away).

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

## Commands (apps with commands)

An app built as a `CmdApp` (`framework/lean/ElmLean/Cmd.lean`; the Send example) asks its host to do
things. Its CLI (`ElmLean.CmdCli.main`) speaks everything above, plus:

* **Every view reply carries `"cmds"`**, the commands that step asked for (possibly `[]`), in the JSON of
  Lean's derived `ToJson` for the app's `Cmd` type: `{"seq":n+1,"view":<node>,"cmds":[…]}`. The initial
  line and `reset` replies carry `"cmds":[]`. Error replies carry none. The commands of a step are
  `cmds msg m` for the message `msg` the step ran and the model `m` **before** it (`Session.step`).
* **Host answers**: `{"host":<answer>}`, where `<answer>` is a value of the app's `Host` type in the JSON
  of Lean's derived `FromJson`. There is no `seq` check: answers arrive asynchronously, and `update`
  decides what an answer means in the current model. The reply is a view at `seq + 1` with that step's
  `cmds`; an answer that does not decode is `bad-json` and changes nothing.
* **Shell-only test command** `{"samples":true}`: the Lean CLI replies `{"seq":n,"samples":[…]}`, plausible
  host answers in the current model, from the app's `CmdCli.Options.samples`. The lockstep driver asks
  the Lean CLI alone and sends one answer to both CLIs; the generated Swift CLI answers `bad-json`.

Line precedence: `reset`, then `samples`, then `host` (when the key is present), then a user event.

The JSON format of commands and answers (both CLIs, and the generated iOS host boundary):

| Lean | JSON |
|---|---|
| structure | object with every field; an `Option` field that is `none` is `null`, and a missing `Option` key decodes as `none` |
| constructor with fields | `{"<ctor>":{"<field>":…}}`, exactly one key |
| constructor without fields | `"<ctor>"` |
| `Nat` | a number with no more fractional digits than its exponent, not negative (`5`, `1e0`, `-0`; not `1.0`) |
| `String`, `Bool`, `List`, `Option` | string, boolean, array, `null` or the value |
