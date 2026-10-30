# LeanNative: Elm-style apps written and proven in Lean 4, compiled to C and run natively on iOS and Mac.
# Relative paths only (the checkout path may contain spaces).
#
#   make check        the framework's checks: build (the shell's grammar is checked as it builds), axiom gate,
#                     protocol harness (see framework/Makefile)

.PHONY: check

check:
	$(MAKE) -C framework check
