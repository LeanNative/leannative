# Shared make rules for an ElmLean app. An app's Makefile sets the variables below, then
#   include $(FW)/app.mk
# Relative paths only: the checkout path may contain spaces, which make cannot quote.
#
#   FW          the framework directory, relative to the app            ../../framework
#   APP         Lean constant of the `App Model Msg` value               Todo.app
#   SWIFT_APP   Swift name of the generated app enum                     TodoApp
#   SCREEN      Swift name of the generated SwiftUI screen               TodoScreen
#   EXE         the app's Lean executable (lakefile `lean_exe`)          todo-cli
#   GATE        the app's axiom-gate file                                Todo/Gate.lean
#   IOS_SCHEME  scheme of the generated iOS app (ios/project.yml)        TodoGen
#   BUNDLE_ID   its bundle identifier                                    art.fralex.elmlean.todo
# Optional:
#   PROTOCOL_FLAGS  extra protocol_test.py flags (`--shape list` for list-shaped apps)
#   EXTRA_CHECKS    more targets for `make check`
#
# Targets:
#   build       lake build: the app, its proofs, its gate (fails on any disallowed axiom), its CLI
#   axioms      the two-layer axiom gate with its log checks (framework/scripts/check-axioms.sh)
#   selftest    the CLI's generic exploration + the app's scripted self-test
#   protocol    the protocol harness against the Lean CLI (the reference the generated code is tested against)
#   gen         regenerate generated/Generated.swift and generated/$(SCREEN).swift with elmgen
#   golden      the checked-in generated files are byte-identical to a fresh elmgen run
#   gen-cli     the generated update/view compiled as a macOS CLI speaking the same protocol
#   gen-test    protocol harness on that CLI + lockstep differential test against the Lean CLI
#   crosscheck  an independent LCNF translation, locked in step with both
#   check       axioms selftest protocol golden gen-test crosscheck $(EXTRA_CHECKS)
#   ios         xcodegen + build + install + launch the generated native app in the iPhone simulator

PY      ?= /opt/homebrew/bin/python3
CLI     := .lake/build/bin/$(EXE)
GEN_CLI := build/$(EXE)-swift
SCRIPTS := $(FW)/scripts

.PHONY: build axioms selftest protocol gen golden gen-cli gen-test crosscheck check ios view

build:
	lake build

axioms:
	$(SCRIPTS)/check-axioms.sh . $(GATE)

selftest: build
	$(CLI) selftest

protocol: build
	$(PY) -I $(SCRIPTS)/protocol_test.py $(PROTOCOL_FLAGS) "$(CLI)"

view: build
	$(CLI) view

gen: build
	lake exe elmgen --app $(APP) --name $(SWIFT_APP) --screen-name $(SCREEN) \
	  --out generated/Generated.swift --screen generated/$(SCREEN).swift

golden: build
	$(SCRIPTS)/gen_golden_test.sh $(APP) $(SWIFT_APP) $(SCREEN)

gen-cli:
	mkdir -p build
	printf 'runElmCli(%s.self)\n' '$(SWIFT_APP)' > build/main.swift
	swiftc -O -o $(GEN_CLI) $(FW)/swift/Runtime.swift generated/Generated.swift build/main.swift

gen-test: build gen-cli
	$(PY) -I $(SCRIPTS)/protocol_test.py $(PROTOCOL_FLAGS) "$(GEN_CLI)"
	$(PY) -I $(SCRIPTS)/lockstep.py "$(CLI)" "$(GEN_CLI)" 400 1
	$(PY) -I $(SCRIPTS)/lockstep.py "$(CLI)" "$(GEN_CLI)" 400 2

crosscheck: build gen-cli
	PROTOCOL_FLAGS='$(PROTOCOL_FLAGS)' $(SCRIPTS)/gen_crosscheck.sh $(APP) $(SWIFT_APP) "$(CLI)" "$(GEN_CLI)"

check: axioms selftest protocol golden gen-test crosscheck $(EXTRA_CHECKS)

ios:
	$(SCRIPTS)/app_sim.sh ios $(IOS_SCHEME) $(BUNDLE_ID) all
