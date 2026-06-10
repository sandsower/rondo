.PHONY: help all setup deps fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, ci, e2e"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

# Opt-in live E2E profile (Linear + Claude). Skipped with a clear reason unless
# RONDO_RUN_LIVE_E2E=1 and live credentials are exported. See README.
e2e:
	@if [ "$$RONDO_RUN_LIVE_E2E" != "1" ]; then \
		echo 'live E2E disabled: set RONDO_RUN_LIVE_E2E=1 (plus LINEAR_API_KEY, RONDO_E2E_LINEAR_TEAM, RONDO_E2E_LINEAR_PROJECT) to run the live Linear + Claude profile; see README "Live end-to-end test"'; \
		exit 0; \
	fi
	$(MIX) test --only live_e2e

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

ci:
	$(MAKE) deps
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
