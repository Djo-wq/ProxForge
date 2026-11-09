#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
for test_file in "$ROOT_DIR/tests/test-schemas.sh" "$ROOT_DIR/tests/test-module-contract.sh" "$ROOT_DIR/tests/test-core.sh"; do
  printf '\n==> %s\n' "${test_file#"$ROOT_DIR/"}"
  bash "$test_file"
done
printf '\nAll ProxForge tests passed.\n'
