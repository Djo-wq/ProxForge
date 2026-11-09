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
  ./proxforge.sh pve doctor
  ./proxforge.sh pve nodes
  ./proxforge.sh pve storages
  ./proxforge.sh pve bridges
  ./proxforge.sh pve vmid next

The Phase 4 Proxmox commands are read-only diagnostics. VM primitives are
exposed through the adapter library and are orchestrated by later phases.
USAGE
}
pve_command() {
  pf_pve_init || return $?
  case "${2:-doctor}" in
    doctor)
      pf_pve_refresh_inventory || return 1
      jq . <<< "$PF_PVE_INVENTORY_JSON"
      ;;
    nodes)
      jq . <<< "$PF_PVE_NODES_JSON"
      ;;
    storages)
      pf_pve_refresh_inventory || return 1
      jq . <<< "$PF_PVE_STORAGES_JSON"
      ;;
    bridges)
      pf_pve_refresh_inventory || return 1
      jq . <<< "$PF_PVE_BRIDGES_JSON"
      ;;
    vmid)
      [[ "${3:-}" == "next" ]] || return "$PF_EXIT_ARGUMENTS"
      pf_pve_next_vmid || return 1
      printf '%s\n' "$PF_PVE_NEXT_VMID"
      ;;
    *)
      pf_core_error "Usage: ./proxforge.sh pve {doctor|nodes|storages|bridges|vmid next}"
      return "$PF_EXIT_ARGUMENTS"
      ;;
  esac
}
main() {
  pf_core_init || return $?
  case "${1:-help}" in
    version)
      printf 'ProxForge %s (Module API %s)\n' "$PF_CORE_VERSION" "$PF_CORE_MODULE_API_VERSION"
      ;;
    help|-h|--help)
      usage
      ;;
    profile)
      case "${2:-}" in
        list)
          pf_core_profiles_list || return 1
          jq . <<< "$PF_CORE_PROFILES_JSON"
          ;;
        show)
          [[ -n "${3:-}" ]] || return "$PF_EXIT_ARGUMENTS"
          pf_core_profile_load "$3" || return "$PF_EXIT_ARGUMENTS"
          jq . <<< "$PF_CORE_PROFILE_JSON"
          ;;
        *)
          pf_core_error "Usage: ./proxforge.sh profile {list|show <profile>}"
          return "$PF_EXIT_ARGUMENTS"
          ;;
      esac
      ;;
    config)
      [[ "${2:-}" == "show" ]] || return "$PF_EXIT_ARGUMENTS"
      jq . <<< "$PF_CORE_CONFIG_JSON"
      ;;
    pve)
      pve_command "$@"
      ;;
    *)
      pf_core_error "Unknown command: $1"
      usage >&2
      return "$PF_EXIT_ARGUMENTS"
      ;;
  esac
}
main "$@"
