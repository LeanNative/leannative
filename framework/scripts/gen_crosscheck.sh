#!/bin/sh
# Cross-check the product translator's Swift CLI with an INDEPENDENT translation of the same Lean app.
# Run from an app's package directory, after `make build gen-cli`:
#
#     ../../framework/scripts/gen_crosscheck.sh <App constant> <Swift app name> <Lean CLI> <product CLI>
#     e.g.  gen_crosscheck.sh Todo.app TodoApp .lake/build/bin/todo-cli build/todo-cli-swift
#
# Steps (paths quoted: the workspace path may contain spaces):
#   1. framework/crosscheck/ToSwiftLCNF.lean translates the app from the compiler IR (LCNF) into
#      build/crosscheck/Generated.swift  (`lake env lean --run`; no lake build, no lakefile change)
#   2. swiftc compiles it with framework/swift/Runtime.swift + a one-line main.swift into build/crosscheck/lcnf-cli
#      (`runElmCli(<App>.self)`, or `runCmdElmCli(<App>.self)` when the translation is an app with
#      commands, i.e. the generated file declares `enum <App>: CmdElmApp`)
#   3. protocol_test.py against the lcnf CLI
#   4. lockstep.py  Lean binary  vs lcnf CLI, $LOCKSTEP_STEPS steps x seeds 1,2
#   5. lockstep.py  product CLI  vs lcnf CLI, with the Lean binary as oracle (host answers), $LOCKSTEP_STEPS steps x seeds 1,2
# Exit 0 only if every step passed. PROTOCOL_FLAGS (optional) is passed to protocol_test.py;
# LOCKSTEP_STEPS (optional, default 400) is the number of steps per lockstep run.
set -eu

FW="$(cd "$(dirname "$0")/.." && pwd)"
PY=/opt/homebrew/bin/python3

if [ $# -ne 4 ]; then
    echo "usage: $0 <App constant> <Swift app name> <Lean CLI> <product CLI>" >&2
    exit 2
fi
APP="$1"; NAME="$2"
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
LEAN_CLI="$(abs "$3")"
PRODUCT="$(abs "$4")"
[ -x "$LEAN_CLI" ] || { echo "gen_crosscheck: Lean CLI missing ($LEAN_CLI); run 'make build' first" >&2; exit 2; }
[ -x "$PRODUCT" ] || { echo "gen_crosscheck: product CLI not found or not executable: $PRODUCT" >&2; exit 2; }

STEPS="${LOCKSTEP_STEPS:-400}"
case "$STEPS" in ''|*[!0-9]*) echo "gen_crosscheck: LOCKSTEP_STEPS must be a number, got '$STEPS'" >&2; exit 2 ;; esac

OUT="$PWD/build/crosscheck"
mkdir -p "$OUT"
rm -f "$OUT/Generated.swift"

echo "== 1/5 generate: LCNF translator -> $OUT/Generated.swift"
lake env lean --run "$FW/crosscheck/ToSwiftLCNF.lean" --app "$APP" --name "$NAME" --out "$OUT/Generated.swift"

# the entry point follows the translation: an app with commands runs CmdSession (Runtime.swift)
if grep -q "^enum $NAME: CmdElmApp {" "$OUT/Generated.swift"; then
    printf 'runCmdElmCli(%s.self)\n' "$NAME" > "$OUT/main.swift"
else
    printf 'runElmCli(%s.self)\n' "$NAME" > "$OUT/main.swift"
fi
echo "   main.swift: $(cat "$OUT/main.swift")"

echo "== 2/5 build: $OUT/lcnf-cli"
swiftc -O -o "$OUT/lcnf-cli" "$FW/swift/Runtime.swift" "$OUT/Generated.swift" "$OUT/main.swift"

echo "== 3/5 protocol test (lcnf CLI)"
# shellcheck disable=SC2086
"$PY" -I "$FW/scripts/protocol_test.py" ${PROTOCOL_FLAGS:-} "$OUT/lcnf-cli"

for seed in 1 2; do
    echo "== 4/5 lockstep: Lean binary vs lcnf CLI ($STEPS steps, seed $seed)"
    "$PY" -I "$FW/scripts/lockstep.py" "$LEAN_CLI" "$OUT/lcnf-cli" "$STEPS" "$seed"
done

for seed in 1 2; do
    echo "== 5/5 lockstep: product CLI vs lcnf CLI ($STEPS steps, seed $seed)"
    # the Lean binary rides along as the oracle: it supplies host answers and must agree too
    "$PY" -I "$FW/scripts/lockstep.py" "$PRODUCT" "$OUT/lcnf-cli" "$STEPS" "$seed" "$LEAN_CLI"
done

echo "gen_crosscheck OK: $PRODUCT agrees with the independent LCNF translation and with the Lean binary"
