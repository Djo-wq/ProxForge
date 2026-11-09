#!/usr/bin/env bash
PF_CORE_ROOT="${PF_CORE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
pf_core_init() {
  local bash_major bash_minor component
  local -a components=(common.sh errors.sh validation.sh config.sh module_loader.sh profiles.sh image_manager.sh proxmox_adapter.sh)
  bash_major="${BASH_VERSINFO[0]:-0}"
  bash_minor="${BASH_VERSINFO[1]:-0}"
  if (( bash_major < 5 || (bash_major == 5 && bash_minor < 1) )); then
    printf '[ERROR] Bash 5.1 or newer is required.\n' >&2
    return 3
  fi
  for component in "${components[@]}"; do
    [[ -r "$PF_CORE_ROOT/core/$component" ]] || {
      printf '[ERROR] Core component is missing: %s\n' "$PF_CORE_ROOT/core/$component" >&2
      return 1
    }
    # shellcheck source=/dev/null
    source "$PF_CORE_ROOT/core/$component" || return 1
  done
  pf_core_require_command jq || return 3
  pf_core_require_command grep || return 3
  pf_core_require_command stat || return 3
  pf_core_require_command mktemp || return 3
  pf_core_config_load || return 2
  pf_core_debug "Core $PF_CORE_VERSION initialized from $PF_CORE_ROOT"
}
