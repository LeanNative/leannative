# Counter — a second ElmLean example

A counter with `-`/`+` buttons, a field whose submit appends a note, a toggle and a Delete
button per note, an All/Pending filter, a caption and Clear. It is smaller than Todo and shows
the same pipeline on a second app: its own package, a `Spec`, the generic self-test with no app
script, the generated native app and the cross-check.

```
Counter/App.lean      the app (`Counter.app`), written in the generated subset
Counter/Proofs.lean   count_inc, count_dec_le, WellTargeted, view_sat, `spec`, counter_reachable_sound
Counter/Gate.lean     the axiom gate
Main.lean             `ElmLean.Cli.main Counter.app args`
generated/, ios/      elmgen's output and the native app's project
```

`counter_reachable_sound` says that after any request trace an advertised, in-sync request
runs `update` on a well-targeted message. In particular `-` is never accepted at count zero,
and every note control names an existing note.

```bash
make check      # gate · selftest · protocol harness · golden · generated CLI + lockstep · cross-check
```

```bash
make ios        # the generated native app in the iPhone simulator
```
