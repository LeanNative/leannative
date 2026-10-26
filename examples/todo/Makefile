# The Todo example. `make check` runs every gate of the app; see framework/app.mk for the targets.
FW         := ../../framework
APP        := Todo.app
SWIFT_APP  := TodoApp
SCREEN     := TodoScreen
EXE        := todo-cli
GATE       := Todo/Gate.lean
IOS_SCHEME := TodoGen
BUNDLE_ID  := art.fralex.elmlean.todo
PROTOCOL_FLAGS := --shape list
EXTRA_CHECKS   := corpus

include $(FW)/app.mk

.PHONY: corpus

# elmgen's corpus, which uses this app's model as its fixture: every unsupported construct is rejected
# naming it, every accepted probe's Swift contains the expected text (ElmGenTests/Negative.lean).
corpus: build
	lake env lean ElmGenTests/Negative.lean

