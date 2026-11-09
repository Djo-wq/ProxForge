#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

bash -n "$ROOT_DIR/proxforge.sh"
for shell_file in "$ROOT_DIR"/core/*.sh "$ROOT_DIR"/tests/*.sh "$ROOT_DIR"/tests/fixtures/modules/*/module.sh "$ROOT_DIR"/distributions/*/module.sh "$ROOT_DIR"/scripts/*.sh; do
  [[ -f "$shell_file" ]] || continue
  bash -n "$shell_file"
done

for test_file in \
  "$ROOT_DIR/tests/test-schemas.sh" \
  "$ROOT_DIR/tests/test-module-contract.sh" \
  "$ROOT_DIR/tests/test-cli.sh" \
  "$ROOT_DIR/tests/test-fedora-module.sh" \
  "$ROOT_DIR/tests/test-debian-module.sh" \
  "$ROOT_DIR/tests/test-core.sh" \
  "$ROOT_DIR/tests/test-image-manager.sh" \
  "$ROOT_DIR/tests/test-proxmox-adapter.sh" \
  "$ROOT_DIR/tests/test-vm-lifecycle.sh" \
  "$ROOT_DIR/tests/test-operations-manager.sh"
do
  printf '\n==> %s\n' "${test_file#"$ROOT_DIR/"}"
  bash "$test_file"
done

printf '\nAll ProxForge tests passed.\n'
