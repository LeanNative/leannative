# The LeanNative framework's own checks; the root Makefile runs them.
#   make check         build · axiom gate · protocol harness against the fake CLI · native support tests (the
#                      manifest's too) ·
#                      the CI scripts' tests (export-evidence)
PY   := /opt/homebrew/bin/python3
FAKE := $(PY) scripts/fake_cli.py

.PHONY: build axioms protocol-fake native-support scripts check

build:
	cd lean && lake build

axioms:
	scripts/check-axioms.sh lean LeanNative/Proofs.lean

# The harness itself is validated against an independent stdlib implementation of the protocol.
protocol-fake:
	$(PY) -I scripts/protocol_test.py --shape list "$(FAKE)"

# The optional native support modules (LeanNative/Native/*), headless: BackgroundRun's lifecycle, the typed
# clients against wire fixtures, EffectScope's invalidation, and the app manifest's checks and spec.
native-support:
	cd lean && lake build background-run-test clients-test effect-scope-test manifest-test && .lake/build/bin/background-run-test \
	  && .lake/build/bin/clients-test && .lake/build/bin/effect-scope-test && .lake/build/bin/manifest-test

# framework/native/ci's Python, against fixtures: export-evidence (scripts/tests).
scripts:
	$(PY) -I -m unittest discover -s scripts/tests

check: build axioms protocol-fake native-support scripts
