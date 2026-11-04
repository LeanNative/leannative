# The LeanNative framework's own checks; the root Makefile runs them.
#   make check         build · axiom gate · protocol harness against the fake CLI and both Lean shells · native
#                      support tests (the manifest's too) · the journey driver's patterns and Html's
#                      decorations · the release tool (App Store Connect against a fake) · the CI scripts'
#                      tests (export-evidence)
PY   := /opt/homebrew/bin/python3
FAKE := $(PY) scripts/fake_cli.py
BIN  := lean/.lake/build/bin

.PHONY: build axioms protocol native-support release scripts check

build:
	cd lean && lake build && lake build LeanNative.Journey LeanNative.Journey.Wire

axioms:
	scripts/check-axioms.sh lean LeanNative/Proofs.lean

# The harness itself is validated against an independent stdlib implementation of the protocol (fake_cli.py, with
# the list-shaped checks), then drives the Lean shells, assuming nothing about the app: a small app on
# LeanNative.Cli and the same with commands on LeanNative.CmdCli (LeanNativeTest/CliApp.lean), each after its own
# `selftest`. The harness waits 0.1 s after every reply, so the three runs go side by side, printed in turn.
protocol:
	cd lean && lake build cli-test-app cmdcli-test-app
	$(BIN)/cli-test-app selftest && $(BIN)/cmdcli-test-app selftest
	@out="$$(mktemp -d)"; \
	$(PY) -I scripts/protocol_test.py --shape list "$(FAKE)" > "$$out/fake_cli.py" 2>&1 & fake=$$!; \
	$(PY) -I scripts/protocol_test.py $(BIN)/cli-test-app > "$$out/cli-test-app" 2>&1 & cli=$$!; \
	$(PY) -I scripts/protocol_test.py $(BIN)/cmdcli-test-app > "$$out/cmdcli-test-app" 2>&1 & cmd=$$!; \
	status=0; wait $$fake || status=1; wait $$cli || status=1; wait $$cmd || status=1; \
	for run in fake_cli.py cli-test-app cmdcli-test-app; do echo "protocol_test.py: $$run"; cat "$$out/$$run"; done; \
	rm -rf "$$out"; exit $$status

# The optional native support modules (LeanNative/Native/*), headless: BackgroundRun's lifecycle, the typed
# clients against wire fixtures, EffectScope's invalidation, and the app manifest's checks and spec; the journey
# driver's text patterns (Journey.Regex, escapeRegex) and Html's chained decorations on the wire.
native-support:
	cd lean && lake build background-run-test clients-test effect-scope-test manifest-test regex-test html-test \
	  && .lake/build/bin/background-run-test && .lake/build/bin/clients-test && .lake/build/bin/effect-scope-test \
	  && .lake/build/bin/manifest-test && .lake/build/bin/regex-test && .lake/build/bin/html-test

# The release tool (LeanNativeRelease) against openssl, plutil, codesign and clang on this Mac: tokens, the
# policy, a small signed app through the bundle checks, and every App Store Connect step but `upload` against
# scripts/fake_asc.py, a local stand-in for the API.
release:
	cd lean && lake build leannative-release release-test && .lake/build/bin/release-test $(PY) ../scripts/fake_asc.py

# framework/native/ci's Python, against fixtures: export-evidence (scripts/tests).
scripts:
	$(PY) -I -m unittest discover -s scripts/tests

check: build axioms protocol native-support release scripts
