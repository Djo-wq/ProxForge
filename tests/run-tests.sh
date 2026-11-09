#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

bash -n "$ROOT_DIR/proxforge.sh"
bash -n "$ROOT_DIR/src/proxforge.sh"

while IFS= read -r -d '' shell_file; do
  bash -n "$shell_file"
done < <(find "$ROOT_DIR/src" "$ROOT_DIR/scripts" "$ROOT_DIR/tests" "$ROOT_DIR/legacy" -type f -name '*.sh' -print0)

test_files=(
  "$ROOT_DIR/tests/test-schemas.sh"
  "$ROOT_DIR/tests/test-module-contract.sh"
  "$ROOT_DIR/tests/test-cli.sh"
  "$ROOT_DIR/tests/test-install.sh"
  "$ROOT_DIR/tests/test-fedora-module.sh"
  "$ROOT_DIR/tests/test-debian-module.sh"
  "$ROOT_DIR/tests/test-core.sh"
  "$ROOT_DIR/tests/test-image-manager.sh"
  "$ROOT_DIR/tests/test-proxmox-adapter.sh"
  "$ROOT_DIR/tests/test-vm-lifecycle.sh"
  "$ROOT_DIR/tests/test-operations-manager.sh"
)

for test_file in "${test_files[@]}"; do
  printf '\n==> %s\n' "${test_file#"$ROOT_DIR/"}"
  bash "$test_file"
done

printf '\n[PASS] All ProxForge hermetic tests passed.\n'
