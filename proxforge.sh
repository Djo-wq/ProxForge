#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/core/bootstrap.sh"
usage() {
  cat <<'USAGE'
ProxForge — autonomous Proxmox VM deployment engine
Usage:
  ./proxforge.sh version
  ./proxforge.sh help
  ./proxforge.sh profile list
  ./proxforge.sh profile show <profile>
  ./proxforge.sh config show

Phase 2 exposes read-only Core and profile commands. VM creation is not yet
implemented by this release of the Core.
USAGE
}
main() {
  pf_core_init || return $?
  case "${1:-help}" in
    version) printf 'ProxForge %s (Module API %s)\n' "$PF_CORE_VERSION" "$PF_CORE_MODULE_API_VERSION" ;;
    help|-h|--help) usage ;;
    profile)
      case "${2:-}" in
        list) pf_core_profiles_list || return 1; jq . <<< "$PF_CORE_PROFILES_JSON" ;;
        show)
          [[ -n "${3:-}" ]] || return "$PF_EXIT_ARGUMENTS"
          pf_core_profile_load "$3" || return "$PF_EXIT_ARGUMENTS"
          jq . <<< "$PF_CORE_PROFILE_JSON"
          ;;
        *) pf_core_error "Usage: ./proxforge.sh profile {list|show <profile>}"; return "$PF_EXIT_ARGUMENTS" ;;
      esac
      ;;
    config) [[ "${2:-}" == "show" ]] || return "$PF_EXIT_ARGUMENTS"; jq . <<< "$PF_CORE_CONFIG_JSON" ;;
    *) pf_core_error "Unknown command: $1"; usage >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}
main "$@"
