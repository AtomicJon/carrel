# Build the Claude Code container variants. Running them is handled by the
# `bin/carrel` launcher (these run/shell/sync/sessions targets just delegate to
# it, so there's a single source of truth).
#
#   make all                             build every variant + list the tags
#   make <variant>                       build a single variant image
#   make run   [TAG=base] [ARGS=…]       run Claude in $(PWD) via bin/carrel
#   make shell [TAG=base]                open a shell instead of Claude
#   make sync                            push host config into carrel's own dir
#   make sessions                        print where session history lives
#   make test                            run the config-layering tests

IMAGE       ?= carrel
TAG         ?= base
CARREL_HOME ?= $(HOME)/.carrel
ARGS        ?=
# bin/carrel owns the variant list, so adding one there is enough.
VARIANTS    := $(shell sed -n 's/^VARIANTS=(\(.*\))$$/\1/p' $(CURDIR)/bin/carrel)

# Invoke the launcher with the Makefile's image/config settings. CARREL_HOME is
# an env var because it's what locates the config; everything else is a flag.
CARREL := CARREL_HOME=$(CARREL_HOME) $(CURDIR)/bin/carrel --image $(IMAGE)

.PHONY: all $(VARIANTS) run shell sync sessions test

all: $(VARIANTS)
	@echo
	@echo "Built images — use with 'carrel <variant>' or 'make run TAG=<variant>':"
	@for v in $(VARIANTS); do printf '  %s\n' "$(IMAGE):$$v"; done

$(VARIANTS):
	docker build --target $@ -t $(IMAGE):$@ .

run:
	@$(CARREL) $(TAG) $(ARGS)

shell:
	@$(CARREL) shell $(TAG)

sync:
	@$(CARREL) sync

sessions:
	@$(CARREL) sessions

test:
	@$(CURDIR)/test/config-test.sh
