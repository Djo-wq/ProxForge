SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help test lint syntax check

help:
	@printf '%s\n' \
	  'make test    Run the complete hermetic test suite' \
	  'make lint    Run ShellCheck on the maintained CLI/install entry points' \
	  'make syntax  Check Bash syntax in maintained and legacy scripts without executing them' \
	  'make check   Run lint and the complete test suite'

test:
	bash tests/run-tests.sh

lint:
	shellcheck --severity=error proxforge.sh src/proxforge.sh scripts/install.sh scripts/uninstall.sh tests/test-install.sh

syntax:
	bash -n proxforge.sh src/proxforge.sh
	find src scripts tests legacy -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do bash -n "$$file"; done

check: lint test
