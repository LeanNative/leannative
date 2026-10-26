# The ElmLean framework's own checks. Apps have theirs (framework/app.mk); the root Makefile runs all.
#   make check         build · axiom gate · protocol harness and bridge tests against the fake CLI
#   make viewer        the generic viewer app (viewer-ios) in the iPhone simulator; make viewer-test: its unit tests
PY   := /opt/homebrew/bin/python3
FAKE := $(PY) scripts/fake_cli.py

.PHONY: build axioms protocol-fake bridge-unit bridge-test-fake check viewer viewer-test

build:
	cd lean && lake build

axioms:
	scripts/check-axioms.sh lean ElmLean/Proofs.lean

# The harness itself is validated against an independent stdlib implementation of the protocol.
protocol-fake:
	$(PY) -I scripts/protocol_test.py --shape list "$(FAKE)"

# Unit tests of bridge.Cli (restart, 503 cli-unavailable, desync, reply timeout); fake CLIs only, no port.
bridge-unit:
	$(PY) -I scripts/bridge_unit_test.py

bridge-test-fake:
	SKIP_RESTART=1 PORT=8791 CLI="$(FAKE)" scripts/bridge_test.sh

check: axioms protocol-fake bridge-unit bridge-test-fake

viewer:
	viewer-ios/scripts/sim.sh all

viewer-test:
	viewer-ios/scripts/sim.sh test
