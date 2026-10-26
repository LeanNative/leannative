# The ElmLean framework's own checks. Apps have theirs (framework/app.mk); the root Makefile runs all.
#   make check         build · axiom gate · protocol harness against the fake CLI
PY   := /opt/homebrew/bin/python3
FAKE := $(PY) scripts/fake_cli.py

.PHONY: build axioms protocol-fake check

build:
	cd lean && lake build

axioms:
	scripts/check-axioms.sh lean ElmLean/Proofs.lean

# The harness itself is validated against an independent stdlib implementation of the protocol.
protocol-fake:
	$(PY) -I scripts/protocol_test.py --shape list "$(FAKE)"

check: axioms protocol-fake
