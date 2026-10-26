#!/bin/bash
# elmgen golden test, run from an app's package directory: a fresh run of the generator must reproduce
# generated/Generated.swift and generated/<Screen>.swift byte for byte (the checked-in files ARE its output).
#
#   ../../framework/scripts/gen_golden_test.sh <App constant> <Swift app name> <Swift screen name>
#   e.g.  gen_golden_test.sh Todo.app TodoApp TodoScreen
set -euo pipefail
if [ $# -ne 3 ]; then
  echo "usage: $0 <App constant> <Swift app name> <Swift screen name>" >&2
  exit 2
fi
APP="$1"; NAME="$2"; SCREEN="$3"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(lake build elmgen >/dev/null \
  && lake exe elmgen --app "$APP" --name "$NAME" --screen-name "$SCREEN" \
       --out "$tmp/Generated.swift" --screen "$tmp/$SCREEN.swift" 2>"$tmp/elmgen.log") \
  || { cat "$tmp/elmgen.log" >&2; echo "FAIL: elmgen did not run" >&2; exit 1; }
for f in Generated.swift "$SCREEN.swift"; do
  if ! cmp -s "$tmp/$f" "generated/$f"; then
    echo "FAIL: generated/$f differs from a fresh elmgen run (checked-in vs fresh); run 'make gen':" >&2
    diff "generated/$f" "$tmp/$f" | head -40 >&2 || true
    exit 1
  fi
done
echo "golden OK (generated/Generated.swift and generated/$SCREEN.swift are byte-identical to elmgen's output for $APP)"
