# The ElmLean framework's own checks; the root Makefile runs them.
#   make check         build · axiom gate · protocol harness against the fake CLI · native support tests
PY   := /opt/homebrew/bin/python3
FAKE := $(PY) scripts/fake_cli.py

.PHONY: build axioms protocol-fake native-support check

build:
	cd lean && lake build

axioms:
	scripts/check-axioms.sh lean ElmLean/Proofs.lean

# The harness itself is validated against an independent stdlib implementation of the protocol.
protocol-fake:
	$(PY) -I scripts/protocol_test.py --shape list "$(FAKE)"

# The optional native support modules (ElmLean/Native/*), headless: BackgroundRun's lifecycle, the typed
# clients against wire fixtures, and EffectScope's invalidation.
native-support:
	cd lean && lake build background-run-test clients-test effect-scope-test && .lake/build/bin/background-run-test \
	  && .lake/build/bin/clients-test && .lake/build/bin/effect-scope-test

check: build axioms protocol-fake native-support
