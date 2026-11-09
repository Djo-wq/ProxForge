#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)

for test_file in \
  "$ROOT_DIR/tests/test-schemas.sh" \
  "$ROOT_DIR/tests/test-module-contract.sh"
do
  printf '\n==> %s\n' "$(basename -- "$test_file")"
  bash "$test_file"
done

printf '\nAll Phase 1 contract tests passed.\n'
