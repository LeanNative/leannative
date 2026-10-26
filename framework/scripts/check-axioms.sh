#!/bin/bash
# Build an ElmLean Lake package (the framework or an app), then run its axiom gate and check the output:
#
#   framework/scripts/check-axioms.sh <package dir> <gate file, relative to the package>
#   e.g.  framework/scripts/check-axioms.sh framework/lean ElmLean/Proofs.lean
#         ../../framework/scripts/check-axioms.sh . Todo/Gate.lean        (from examples/todo)
#
#   * the build log carries no "declaration uses `sorry`" warning (quote-agnostic pattern: Lean 4.35
#     prints backticks, older versions printed ASCII quotes);
#   * every `#assert_axioms` line reports "OK, axioms:" (as many lines as assertions);
#   * `#assert_all_axioms` reports "all theorems OK: <k> checked under <namespaces>" with k >= that count;
#   * no "disallowed axiom" and no "error" anywhere in the gate's output.
set -euo pipefail
if [ $# -ne 2 ]; then
  echo "usage: $0 <package dir> <gate file relative to it>" >&2
  exit 2
fi
cd "$1"
GATE="$2"

echo "== lake build"
build_out="$(mktemp)"
trap 'rm -f "$build_out"' EXIT
if ! lake build 2>&1 | tee "$build_out"; then
  echo "FAIL: lake build failed" >&2
  exit 1
fi
if grep -qE 'declaration uses .sorry.' "$build_out"; then
  grep -E 'declaration uses .sorry.' "$build_out" >&2
  echo "FAIL: build output contains a 'declaration uses sorry' warning" >&2
  exit 1
fi

echo "== axioms ($GATE)"
if [ ! -f "$GATE" ]; then
  echo "FAIL: gate file $GATE not found in $(pwd)" >&2
  exit 1
fi
expected="$(grep -c '^#assert_axioms' "$GATE" || true)"
scans="$(grep -c '^#assert_all_axioms' "$GATE" || true)"
if [ "$scans" -ne 1 ]; then
  echo "FAIL: expected exactly one '#assert_all_axioms' line in $GATE, found $scans" >&2
  exit 1
fi
lean_out="$(lake env lean "$GATE" 2>&1)" || {
  printf '%s\n' "$lean_out" >&2
  echo "FAIL: lean $GATE exited non-zero" >&2
  exit 1
}
got="$(grep -c 'OK, axioms:' <<<"$lean_out" || true)"
if grep -q 'disallowed axiom' <<<"$lean_out"; then
  printf '%s\n' "$lean_out" >&2
  echo "FAIL: a theorem depends on a disallowed axiom" >&2
  exit 1
fi
if grep -q 'error' <<<"$lean_out"; then
  printf '%s\n' "$lean_out" >&2
  echo "FAIL: lean reported an error" >&2
  exit 1
fi
if [ "$expected" -eq 0 ] || [ "$got" -ne "$expected" ]; then
  printf '%s\n' "$lean_out" >&2
  echo "FAIL: $expected '#assert_axioms' lines in $GATE but $got 'OK, axioms:' lines in the output" >&2
  exit 1
fi
scanned="$(sed -nE 's/.*all theorems OK: ([0-9]+) checked under .*/\1/p' <<<"$lean_out")"
if ! [[ "$scanned" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "$lean_out" >&2
  echo "FAIL: expected exactly one 'all theorems OK: <k> checked under <namespaces>' line, got '$scanned'" >&2
  exit 1
fi
if [ "$scanned" -lt "$expected" ]; then
  echo "FAIL: #assert_all_axioms scanned only $scanned theorems, fewer than the $expected named assertions" >&2
  exit 1
fi
grep 'OK, axioms:' <<<"$lean_out"
grep 'all theorems OK:' <<<"$lean_out"
echo "axioms OK ($got/$expected assertions, $scanned theorems scanned)"
