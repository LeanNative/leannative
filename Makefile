# ElmLean: a framework for Elm-style apps written and proven in Lean 4 and generated as native SwiftUI apps.
# Relative paths only (the checkout path may contain spaces).
#
#   make check        the framework's checks, then every example's (see framework/Makefile, framework/app.mk)
#   make framework    the framework alone;  make todo / make counter / make send  one example
#   make new-app NAME=Notes [DIR=apps/notes]   scaffold a new app from framework/template

EXAMPLES := examples/todo examples/counter examples/send

.PHONY: check framework todo counter send new-app template-test

check: framework todo counter send template-test

framework:
	$(MAKE) -C framework check

todo:
	$(MAKE) -C examples/todo check

counter:
	$(MAKE) -C examples/counter check

send:
	$(MAKE) -C examples/send check

new-app:
	framework/scripts/new_app.sh "$(NAME)" "$(or $(DIR),apps/$(shell echo '$(NAME)' | tr '[:upper:]' '[:lower:]'))"

# Scaffold a throwaway app from the template and run its whole `make check` (proves the template works).
template-test:
	framework/scripts/template_test.sh
