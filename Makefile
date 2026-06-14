# Build the Claude Code container variants. Running them is handled by the
# `bin/carrel` launcher (these run/shell/sync/sessions targets just delegate to
# it, so there's a single source of truth).
#
#   make all                             build every variant + list the tags
#   make base | rust | tauri             build a single variant image
#   make run   [TAG=base] [ARGS=…]       run Claude in $(PWD) via bin/carrel
#   make shell [TAG=base]                open a shell instead of Claude
#   make sync                            push host config into carrel's own dir
#   make sessions                        print where session history lives

IMAGE       ?= carrel
TAG         ?= base
CARREL_HOME ?= $(HOME)/.carrel
ARGS        ?=
VARIANTS    := base rust tauri

# Invoke the launcher with the Makefile's image/config settings.
CARREL := CARREL_IMAGE=$(IMAGE) CARREL_HOME=$(CARREL_HOME) $(CURDIR)/bin/carrel

.PHONY: all base rust tauri run shell sync sessions

all: $(VARIANTS)
	@echo
	@echo "Built images — use with 'carrel <variant>' or 'make run TAG=<variant>':"
	@for v in $(VARIANTS); do printf '  %s\n' "$(IMAGE):$$v"; done

base rust tauri:
	docker build --target $@ -t $(IMAGE):$@ .

run:
	@$(CARREL) $(TAG) $(ARGS)

shell:
	@$(CARREL) shell $(TAG)

sync:
	@$(CARREL) sync

sessions:
	@$(CARREL) sessions
