CRAWL_REPO ?= $(HOME)/code/crawl
VERSIONS   := $(shell grep -v '^\#' versions.conf | awk 'NF {print $$1}')
DEPTH      ?= D:8
SEED       ?=
SEEDS      ?=
V          ?= trunk

.DEFAULT_GOAL := help

help:
	@echo "DCSS seed explorer"
	@echo
	@echo "  make provision              build every version in versions.conf"
	@echo "  make provision-<version>    build one version"
	@echo "  make versions               list configured versions and build state"
	@echo
	@echo "  make seed SEED=<n> [V=<version>] [DEPTH=<lvl>]"
	@echo "                              dump one seed and render a report"
	@echo "  make batch SEEDS=<file> [V=<version>]"
	@echo "                              dump many seeds (batched, parallel)"
	@echo "  make report IN=<jsonl>      render an existing dump to markdown"
	@echo
	@echo "  make clean                  remove outputs"
	@echo "  make distclean              also remove builds and sandboxes"
	@echo
	@echo "versions: $(VERSIONS)     (default V=$(V), DEPTH=$(DEPTH))"

versions:
	@printf '%-10s %-12s %s\n' VERSION BUILT REF
	@awk '!/^#/ && NF {print $$1, $$2}' versions.conf | while read -r n r; do \
	    if [ -x "builds/$$n/crawl-ref/source/crawl" ]; then b=yes; else b=no; fi; \
	    printf '%-10s %-12s %s\n' "$$n" "$$b" "$$r"; \
	done

provision: $(addprefix provision-,$(VERSIONS))

provision-%:
	@ref=$$(awk -v n=$* '!/^#/ && $$1==n {print $$2}' versions.conf); \
	if [ -z "$$ref" ]; then echo "no such version '$*' in versions.conf" >&2; exit 1; fi; \
	CRAWL_REPO=$(CRAWL_REPO) tools/provision "$*" "$$ref"

seed:
	@if [ -z "$(SEED)" ]; then echo "usage: make seed SEED=<n> [V=<version>]" >&2; exit 1; fi
	@tools/explore $(V) -d "$(DEPTH)" -o out/$(V)-$(SEED).jsonl $(SEED)
	@lua scripts/render_seed_report.lua out/$(V)-$(SEED).jsonl > out/$(V)-$(SEED).md
	@echo "==> out/$(V)-$(SEED).md"

batch:
	@if [ -z "$(SEEDS)" ]; then echo "usage: make batch SEEDS=<file> [V=<version>]" >&2; exit 1; fi
	@tools/explore $(V) -d "$(DEPTH)" -f "$(SEEDS)" -o out/$(V)-batch.jsonl

report:
	@if [ -z "$(IN)" ]; then echo "usage: make report IN=<file.jsonl>" >&2; exit 1; fi
	@lua scripts/render_seed_report.lua "$(IN)" > "$(IN:.jsonl=.md)"
	@echo "==> $(IN:.jsonl=.md)"

clean:
	rm -rf out

distclean: clean
	@for v in $(VERSIONS); do \
	    if [ -d "builds/$$v" ]; then git -C $(CRAWL_REPO) worktree remove --force "builds/$$v" || true; fi; \
	done
	rm -rf builds sandboxes .venv

.PHONY: help versions provision seed batch report clean distclean
