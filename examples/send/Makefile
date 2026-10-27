# The Send example: Winnow's Send review flow, an ElmLean app with commands. `make check` runs every gate
# of the app (see framework/app.mk); `make ios` builds the native app against Winnow's WalletCore.
FW         := ../../framework
APP        := Send.app
SWIFT_APP  := SendApp
SCREEN     := SendScreen
EXE        := send-cli
GATE       := Send/Gate.lean
IOS_SCHEME := SendGen
BUNDLE_ID  := art.fralex.elmlean.send
CLI_RUNNER := runCmdElmCli
# the deep states (signing, broadcast) need host answers at the right moment: walk longer
LOCKSTEP_STEPS := 3000
EXTRA_CHECKS   := host-test
# the Winnow checkout whose WalletCore (and test fixtures) the iOS app's host uses
WINNOW     ?= $(HOME)/src/winnow-claude
export WINNOW

include $(FW)/app.mk

.PHONY: host-test winnow

# host-test and ios build against a Winnow checkout: say so in one line when there is none
winnow:
	@test -f "$(WINNOW)/Package.swift" || { echo "examples/send: no Winnow checkout at $(WINNOW); set WINNOW=<path to a winnowwallet/winnow checkout>" >&2; exit 2; }

ios: winnow

# The host test: the generated app + framework runtime + the iOS app's SendWallet against Winnow's WalletCore
# on macOS (no authentication, no UI). Sources are copied next to hosttest/Package.swift under build/.
host-test: winnow gen-cli
	rm -rf build/hosttest && mkdir -p build/hosttest/Sources
	cp hosttest/Package.swift build/hosttest/
	cp $(FW)/swift/Runtime.swift generated/Generated.swift ios/App/SendWallet.swift build/hosttest/Sources/
	cp hosttest/main.swift build/hosttest/Sources/main.swift
	cd build/hosttest && swift run -c release send-host-test
