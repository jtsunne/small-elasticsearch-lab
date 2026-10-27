SHELL := /bin/bash
.DEFAULT_GOAL := help

SCENARIO ?=
HOST_ID ?=
BENCH_ARGS ?=

SCENARIO_DIR := scenarios/$(SCENARIO)
COMPOSE = docker compose --project-directory $(SCENARIO_DIR) --env-file versions.env \
	$(if $(wildcard $(SCENARIO_DIR)/.env),--env-file $(SCENARIO_DIR)/.env) \
	-f $(SCENARIO_DIR)/compose.yaml

SHELL_SCRIPTS = $(shell git ls-files --cached --others --exclude-standard '*.sh' 2>/dev/null)

.PHONY: help up down test bench host-info loader check scenario-exists

help:
	@echo "make up SCENARIO=<name>         start a scenario"
	@echo "make down SCENARIO=<name>       stop a scenario and delete its volumes"
	@echo "make test SCENARIO=<name>       run the scenario checks (TAP output)"
	@echo "make bench BENCH_ARGS='...'     run bench/run.sh, see bench/README.md"
	@echo "make host-info HOST_ID=<label>  print the host record"
	@echo "make loader                     build bench/loader/loader"
	@echo "make check                      go vet, go test, bash -n, shellcheck"
	@echo
	@echo "Scenarios with a compose file:"
	@for d in scenarios/*/; do [ -f "$$d/compose.yaml" ] && echo "  $$(basename $$d)"; done; true

scenario-exists:
	@if [ -z "$(SCENARIO)" ]; then echo "error: set SCENARIO=<name>, see scenarios/" >&2; exit 2; fi
	@if [ ! -d "$(SCENARIO_DIR)" ]; then echo "error: unknown scenario '$(SCENARIO)'" >&2; exit 2; fi
	@if [ ! -f "$(SCENARIO_DIR)/compose.yaml" ]; then \
		echo "error: scenario '$(SCENARIO)' has no compose.yaml yet; it is not written or tested, see $(SCENARIO_DIR)/README.md" >&2; exit 2; fi

up: scenario-exists
	$(COMPOSE) up -d --wait

down: scenario-exists
	$(COMPOSE) down -v

test: scenario-exists
	@if [ ! -x tests/run-scenario.sh ]; then \
		echo "error: tests/run-scenario.sh does not exist yet (test harness, plan task T5)" >&2; exit 2; fi
	tests/run-scenario.sh $(SCENARIO)

bench:
	bench/run.sh $(BENCH_ARGS)

host-info:
	@if [ -z "$(HOST_ID)" ]; then echo "error: set HOST_ID=<label>, for example laptop-8c32g-nvme-01" >&2; exit 2; fi
	bench/host-info.sh --host-id "$(HOST_ID)"

loader:
	cd bench/loader && go build -trimpath -o loader .

check:
	cd bench/loader && go vet ./... && go test ./...
	@for f in $(SHELL_SCRIPTS); do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck $(SHELL_SCRIPTS); \
	else echo "shellcheck not installed, skipped" >&2; fi
