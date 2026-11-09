#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}") || {
  printf '[ERROR] Unable to resolve ProxForge launcher path.\n' >&2
  exit 1
}
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
exec "$SCRIPT_DIR/src/proxforge.sh" "$@"
