# ElmLean: a framework for Elm-style apps written and proven in Lean 4, served by a Lean CLI to a generic
# SwiftUI viewer or generated as a native SwiftUI app. Relative paths only (the checkout path may contain spaces).
#
#   make check        the framework's checks, then every example's (see framework/Makefile, framework/app.mk)
#   make framework    the framework alone;  make todo / make counter  one example
#   make serve        the Todo example's CLI behind the bridge on http://127.0.0.1:8787 (for the viewer app)
#   make new-app NAME=Notes [DIR=apps/notes]   scaffold a new app from framework/template

EXAMPLES := examples/todo examples/counter

.PHONY: check framework todo counter serve new-app template-test

check: framework todo counter template-test

framework:
	$(MAKE) -C framework check

todo:
	$(MAKE) -C examples/todo check

counter:
	$(MAKE) -C examples/counter check

serve:
	$(MAKE) -C examples/todo serve

new-app:
	framework/scripts/new_app.sh "$(NAME)" "$(or $(DIR),apps/$(shell echo '$(NAME)' | tr '[:upper:]' '[:lower:]'))"

# Scaffold a throwaway app from the template and run its whole `make check` (proves the template works).
template-test:
	framework/scripts/template_test.sh
