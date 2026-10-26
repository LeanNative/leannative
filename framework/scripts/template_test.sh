#!/bin/bash
# Scaffold a throwaway app from framework/template into build/template-test/Demo and run its whole
# pipeline: lake build (proofs + gate), make gen, make check (axioms, selftest, protocol harness,
# golden, generated-CLI protocol + lockstep, LCNF cross-check). Proves the template is a working app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
rm -rf build/template-test
framework/scripts/new_app.sh Demo build/template-test/Demo
cd build/template-test/Demo
make gen
make check
echo "template_test OK: a fresh app from framework/template passes make check"
