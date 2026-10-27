# framework/crosscheck — the independent cross-check translator

A **second, independent translation** of an ElmLean app from Lean to Swift, used only to
cross-check the product translator. It is not a product: its output is A-normal form that no
human reads, it lives outside the Lake build, and nothing in the app or the iOS project depends
on it.

## Why two translators

The product translator works on **elaborated terms** (`ConstantInfo.value`, the expression tree
the theorems are about). This one works on the **compiler's IR**: for every declaration reachable
from the `App Model Msg` constant it calls `Lean.Compiler.LCNF.toDecl` (kernel definition →
LCNF, `match` lowered to `cases`) followed by one `simp` pass with `inlineDefs := false`
(typeclass projections such as `instHAdd … # 0` resolve to `Nat.add`, matcher alternatives are
inlined, library definitions are not). Different input representation, different code, same
Lean definitions. If both translations agree with each other *and* with the Lean binary over a
long random walk, a bug would have to be present in two unrelated pipelines in the same way.

The two translators share nothing but the Swift side they target: `framework/swift/Runtime.swift`
(the `Html` mirror, the JSON reader, the `Session` / `CmdSession` loops, the `LeanCodable`
conformances of `Int`/`String`/`Bool`/`Array`/`Optional`) and the one-line `main.swift`
(`runElmCli(<App>.self)`, or `runCmdElmCli(<App>.self)` for an app with commands). The runtime is therefore *not* covered by the cross-check; it is
covered by `framework/scripts/protocol_test.py` and by the lockstep run against the Lean binary.

## Files

| file | role |
| --- | --- |
| `ToSwiftLCNF.lean` | the translator, a `lake env lean --run` script (`main (args)`); no lakefile entry, no Lake library |
| `../scripts/gen_crosscheck.sh` | the driver: generate, pick `main.swift` (`runCmdElmCli` iff the output declares `enum <App>: CmdElmApp`), build, protocol test, lockstep ×4 |
| `<app>/build/crosscheck/Generated.swift` | output (ignored by git) |
| `<app>/build/crosscheck/lcnf-cli` | the cross-check CLI, speaking the ndjson protocol of `PROTOCOL.md` |

## Running

Every app runs it as part of `make check` (target `crosscheck` of `framework/app.mk`), after its
Lean CLI (`make build`) and its product CLI (`make gen-cli`) exist. By hand, from the app's directory:

    ../../framework/scripts/gen_crosscheck.sh Todo.app TodoApp .lake/build/bin/todo-cli build/todo-cli-swift

Steps and gates:

1. `lake env lean --run ../../framework/crosscheck/ToSwiftLCNF.lean --app Todo.app --name TodoApp --out build/crosscheck/Generated.swift`
   (the translation **fails loud** on anything outside its whitelist, and the file is written only
   after the whole translation succeeded)
2. `swiftc -O` with `framework/swift/Runtime.swift` and a one-line `main.swift`
3. `protocol_test.py` against the lcnf CLI → `protocol OK`
4. `lockstep.py <Lean binary> <lcnf CLI> $LOCKSTEP_STEPS {1,2}` → `lockstep OK`
5. `lockstep.py <product CLI> <lcnf CLI> $LOCKSTEP_STEPS {1,2}` → `lockstep OK`

`LOCKSTEP_STEPS` (default 400) is the step count of each lockstep run; `framework/app.mk` passes it
through (the Send example sets 3000).

Translator flags: `--app <Name>` (default `Todo.app`), `--name <Ident>` (the Swift
`enum … : ElmApp`, or `: CmdElmApp`), `--out <path>` (required), `--module <Name>` (modules to import at run time,
repeatable; default: the app constant's root module). The script itself only imports
`ElmLean.Html` and `ElmLean.Program` (framework names); the app comes from the modules imported
at run time.

## Apps with commands (`CmdApp`)

The app value is searched for `CmdApp.mk toApp cmds host` first (it contains an `App.mk`), else for a
plain `App.mk`. `toApp` may be the inline `App.mk` record or a named `App` constant; `cmds` must be a
named constant and is translated like `update` (`static func cmds(_:_:) -> [Cmd]`); `host` is what LCNF
makes of `host := Msg.host` (a local lambda `fun h => Msg.host h`, translated in place) or a named
function (called). The enum is `enum <Name>: CmdElmApp`; `cmds` and `host` are reserved member names.
The names `ElmLean.CmdApp`/`.mk` are compared unchecked, so a pure app's package need not have built
`ElmLean.Cmd`. A pure app gets no codec prelude, no `cmds`/`host` and `: ElmApp`, so its output is
unaffected by command support.

**The JSON codec judgment.** `Cmd`, `Host` and every user type reachable from their constructor fields
(`Nat`, `String`, `Bool`, `List`, `Option` and user inductives only; anything else is rejected) get an
`extension T: LeanCodable` printed by this translator, transcribed from Lean's deriving handler
(`Lean.Elab.Deriving.FromToJson`) and `Lean.Json`'s getters, not from the product's output:

* structure → object of all fields, `none` → `null`; decoded with `getObjValAs?` =
  `fromJson? (getObjValD j k)`: a missing key or a non-object reads as `null`, which only an `Option`
  accepts (`none`); extra keys are ignored. A `?`-suffixed field (Lean omits it when `none`) and a
  structure with a parent (Lean flattens it) are rejected.
* constructor without fields → `"tag"`; decoded from anything whose `getTag?` is the tag (the string,
  or a one-key object whatever its payload).
* constructor with named fields → `{"tag":{"field":…}}`; decoded with `parseCtorFields`, i.e.
  `getObjVal?` for the tag and for every field: a missing key is an error **even for an `Option`
  field** (unlike a structure). A constructor with an anonymous field (positional JSON) is rejected.
* `Nat` → Runtime.swift's `Int.fromLean` (a natural within `Int` range).
* Lean's parser keeps the **last** of repeated keys and compares keys exactly, so the codec shims
  (`leanObjVal`, `leanObjValD`, `leanTag`, emitted only for command apps) look up the last occurrence
  with `leanStrEq` and count distinct keys; tags are compared with `leanStrEq`, not Swift `switch`.
* The instances must be the derived ones: `ToJson T` for every type, `FromJson T` for everything the
  host answer reaches, each resolved by instance synthesis and checked to have the deriving handler's
  shape `inst := ToJson.mk T inst.toJson`; a hand-written instance is rejected. A command-only type
  without `FromJson` gets a decoder that always fails (`LeanCodable` requires one; it is never called).

Checked by hand against the Lean CLI (`send-cli`) beyond what lockstep sends: extra keys, missing
`Option` keys in structures, `{"low":5}` for a nullary constructor, a non-natural `1.0` and repeated
keys all give the Lean answer. The product codec (`elmgen`) differs on inputs lockstep never
produces: repeated keys (observed: it takes the first, and `{"a":…,"a":…}` fails its one-key test) and,
by its code (Send has no such field), a missing `Option` key inside a constructor payload, which it
would accept as `none` where Lean rejects it.

Coverage note: `lockstep.py` injects host answers only when CLI A answers `{"samples":true}`, which
only the Lean CLI does; so step 4 (Lean vs lcnf) exercises host answers and compares `cmds`, while step
5 (product vs lcnf) compares `cmds` on user events only.

## What the translation commits to

Every semantic judgment is logged once, to stderr (`ToSwiftLCNF: judgment: …`) and as a trailer
comment at the end of the generated file; only the judgments the app actually exercises appear
(the Todo app triggers 7 of them). The full set:

* `Nat → Int` (Lean naturals are unbounded; Swift `Int` is 64-bit; literals ≥ 2^62 are rejected,
  arithmetic leaving `Int` range traps)
* `String.Slice → String` (a slice is materialised by copying; `String.Slice.copy` is the identity)
* `Decidable p → Bool` (LCNF has already erased the proposition)
* `List α → [α]`, `x :: xs → [x] + xs`; `Option α → Optional<α>` (nested options stay nested)
* `Html msg → Html<Msg>` of `Runtime.swift` (handlers become closures)
* `Nat.repr → String(Int)`; `Nat.sub → max(a - b, 0)`; `String.length → unicodeScalars.count`
* **String equality is exact**: `=`, `==`, `!=` on `String` become `leanStrEq`
  (`unicodeScalars.elementsEqual`); Swift's `String ==` (Unicode canonical equivalence) is never used
* **`DecidableEq` on a user type is translated as a function**: the Lean instance (derived or
  hand-written) is itself translated, so exactly Lean's decision procedure runs. No Swift
  `Equatable` is emitted for any user type.
* `==` on `Option α` (core's derived `BEq (Option α)` over α's `instBEqOfDecidableEq`) → a switch:
  none/none true, some/some by α's equality, otherwise false (`DecidableEq` on `Option` is still rejected)
* `match` on `Option` → `switch` with `.none`/`.some(let x)`; `match` on `List` →
  `isEmpty` / `[0]` / `Array(dropFirst())` (the tail is copied)
* recursive inductive types → `indirect enum`; a recursive structure is rejected
* `CmdApp` → `enum … : CmdElmApp` (`cmds` from the pre-state, as `Session.step`), and the JSON codec
  judgment of the section above

Other properties: Lean doc comments are carried over as `///`; generated names are checked for
collisions with each other, with `Runtime.swift` and with the prelude at translation time
(helpers whose short name is taken, e.g. a helper called `update`, get a numbered name; type
collisions are errors); constructor patterns on anything other than `Bool`/`Option`/`List`/user
types are rejected (`Nat.zero`/`Nat.succ` included).

## What it rejects (by design)

Everything outside the whitelist in `libTemplate`/`translateConst`: `List.foldl`, `String.toList`,
`Float`, `Option.decidableEqNone`, `DecidableEq` on `Option`/`List` values (`==` on `Option` is accepted, see above), `cases` on `Nat`, dependent
fields, indexed families, parametric user types, recursive structures, `extern` declarations,
natural literals ≥ 2^62, … Each rejection names the construct: `ToSwiftLCNF: unsupported <what>`,
exit code 1, no output file.

## Re-running the probe corpus

The translator exposes `ToSwiftLCNF.run` and `ToSwiftLCNF.translateOne` as `CoreM` functions.
To translate definitions that are not in the library (negative tests, probe apps), concatenate the
translator body (minus its `import` lines) after `import Lean` / `import Todo`, append the
probe definitions and an `#eval`, and run it with `lake env lean <file>` (no `--run`). The spike's
negative corpus and the judges' probe set were run that way; the lowering of `Option`/`List`
patterns means `optCase`/`recLen`/`pOptMatch`/`pRec` are now accepted (and validated against a
Lean reference by lockstep), while `foldSum`, `strLen`, `floaty`, `natCase`, `pFoldl`,
`pNestedView`, `DecidableEq` (`=`) on `Option`/`List` values and a recursive structure are still
rejected loudly (`==` on `Option` is now accepted).

## Known limitations (deliberate: this is a cross-check, not the product)

* `isUserName` is a namespace-prefix test on the app constant, so an `App` whose `Model` or
  helpers live in a parent or sibling namespace is rejected with a message that names the
  type rather than the real reason.
* A few rejections name a compiler or instance auxiliary (`Eq.ndrec_symm` for a `Nat`-literal
  pattern, `instInhabitedNat` for `List.head!`) instead of the user-level construct. They are
  still loud (exit 1, nothing written).
* Static helper calls are printed `Self.helper(...)` so a local binder can never shadow a
  helper; the product translator does the same.
