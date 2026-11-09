SHELL := /usr/bin/env bash

.PHONY: help test lint syntax check

help:
	@printf '%s\n' \
	  'make test    Run the complete hermetic test suite' \
	  'make lint    Run ShellCheck on the maintained CLI/install entry points' \
	  'make syntax  Run the Bash syntax checks and complete test runner' \
	  'make check   Run lint and the complete test suite'

test:
	bash tests/run-tests.sh

lint:
	shellcheck --severity=error proxforge.sh scripts/install.sh scripts/uninstall.sh tests/test-install.sh

syntax:
	bash -n proxforge.sh
	for file in core/*.sh scripts/*.sh tests/*.sh distributions/*/module.sh; do \
	  [[ ! -f "$$file" ]] || bash -n "$$file"; \
	done

check: lint test
