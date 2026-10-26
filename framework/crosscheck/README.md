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
(the `Html` mirror, the JSON reader, the `Session` loop) and the one-line `main.swift`
(`runElmCli(<App>.self)`). The runtime is therefore *not* covered by the cross-check; it is
covered by `framework/scripts/protocol_test.py` and by the lockstep run against the Lean binary.

## Files

| file | role |
| --- | --- |
| `ToSwiftLCNF.lean` | the translator, a `lake env lean --run` script (`main (args)`); no lakefile entry, no Lake library |
| `../scripts/gen_crosscheck.sh` | the driver: generate, build, protocol test, lockstep ×4 |
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
4. `lockstep.py <Lean binary> <lcnf CLI> 400 {1,2}` → `lockstep OK`
5. `lockstep.py <product CLI> <lcnf CLI> 400 {1,2}` → `lockstep OK`

Translator flags: `--app <Name>` (default `Todo.app`), `--name <Ident>` (the Swift
`enum … : ElmApp`), `--out <path>` (required), `--module <Name>` (modules to import at run time,
repeatable; default: the app constant's root module). The script itself only imports
`ElmLean.Html` and `ElmLean.Program` (framework names); the app comes from the modules imported
at run time.

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
* `match` on `Option` → `switch` with `.none`/`.some(let x)`; `match` on `List` →
  `isEmpty` / `[0]` / `Array(dropFirst())` (the tail is copied)
* recursive inductive types → `indirect enum`; a recursive structure is rejected

Other properties: Lean doc comments are carried over as `///`; generated names are checked for
collisions with each other, with `Runtime.swift` and with the prelude at translation time
(helpers whose short name is taken, e.g. a helper called `update`, get a numbered name; type
collisions are errors); constructor patterns on anything other than `Bool`/`Option`/`List`/user
types are rejected (`Nat.zero`/`Nat.succ` included).

## What it rejects (by design)

Everything outside the whitelist in `libTemplate`/`translateConst`: `List.foldl`, `String.toList`,
`Float`, `Option.decidableEqNone`, equality on `Option`/`List` values, `cases` on `Nat`, dependent
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
`pNestedView`, equality on `Option`/`List` values and a recursive structure are still rejected loudly.

## Known limitations (deliberate: this is a cross-check, not the product)

* `isUserName` is a namespace-prefix test on the app constant, so an `App` whose `Model` or
  helpers live in a parent or sibling namespace is rejected with a message that names the
  type rather than the real reason.
* A few rejections name a compiler or instance auxiliary (`Eq.ndrec_symm` for a `Nat`-literal
  pattern, `instInhabitedNat` for `List.head!`) instead of the user-level construct. They are
  still loud (exit 1, nothing written).
* Static helper calls are printed `Self.helper(...)` so a local binder can never shadow a
  helper; the product translator does the same.
