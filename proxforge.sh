#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
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

  ./proxforge.sh deploy <distribution> <release|stable|latest> <profile> <storage> <bridge> [vm-name] [vmid|auto]
  ./proxforge.sh operation list
  ./proxforge.sh operation show <operation-uuid>
  ./proxforge.sh operation reconcile <operation-uuid>

VM creation is performed only by the explicit deploy command. Proxmox
diagnostic commands remain read-only.
USAGE
}

pve_command() {
  local subcommand=doctor
  if (( $# >= 2 )); then subcommand="$2"; fi
  pf_pve_init || return $?
  case "$subcommand" in
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
      (( $# == 3 )) && [[ "$3" == "next" ]] || return "$PF_EXIT_ARGUMENTS"
      pf_pve_next_vmid || return 1
      printf '%s\n' "$PF_PVE_NEXT_VMID"
      ;;
    *)
      pf_core_error "Usage: ./proxforge.sh pve {doctor|nodes|storages|bridges|vmid next}"
      return "$PF_EXIT_ARGUMENTS"
      ;;
  esac
}

deploy_command() {
  local name="" vmid=auto
  (( $# >= 6 && $# <= 8 )) || {
    pf_core_error "Usage: ./proxforge.sh deploy <distribution> <release> <profile> <storage> <bridge> [vm-name] [vmid|auto]"
    return "$PF_EXIT_ARGUMENTS"
  }
  if (( $# >= 7 )); then name="$7"; fi
  if (( $# == 8 )); then vmid="$8"; fi
  pf_vm_lifecycle_deploy "$2" "$3" "$4" "$5" "$6" "$name" "$vmid"
}

operation_command() {
  local subcommand=""
  (( $# >= 2 )) && subcommand="$2"
  case "$subcommand" in
    list)
      (( $# == 2 )) || return "$PF_EXIT_ARGUMENTS"
      pf_vm_lifecycle_operation_list
      ;;
    show)
      (( $# == 3 )) || return "$PF_EXIT_ARGUMENTS"
      pf_vm_lifecycle_operation_show "$3"
      ;;
    reconcile)
      (( $# == 3 )) || return "$PF_EXIT_ARGUMENTS"
      pf_vm_lifecycle_reconcile "$3"
      ;;
    *)
      pf_core_error "Usage: ./proxforge.sh operation {list|show <uuid>|reconcile <uuid>}"
      return "$PF_EXIT_ARGUMENTS"
      ;;
  esac
}

main() {
  local command=help
  (( $# >= 1 )) && command="$1"
  pf_core_init || return $?
  case "$command" in
    version)
      printf 'ProxForge %s (Module API %s)\n' "$PF_CORE_VERSION" "$PF_CORE_MODULE_API_VERSION"
      ;;
    help|-h|--help)
      usage
      ;;
    profile)
      (( $# >= 2 )) || return "$PF_EXIT_ARGUMENTS"
      case "$2" in
        list)
          (( $# == 2 )) || return "$PF_EXIT_ARGUMENTS"
          pf_core_profiles_list || return 1
          jq . <<< "$PF_CORE_PROFILES_JSON"
          ;;
        show)
          (( $# == 3 )) || return "$PF_EXIT_ARGUMENTS"
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
      (( $# == 2 )) && [[ "$2" == "show" ]] || return "$PF_EXIT_ARGUMENTS"
      jq . <<< "$PF_CORE_CONFIG_JSON"
      ;;
    pve)
      pve_command "$@"
      ;;
    deploy)
      deploy_command "$@"
      ;;
    operation)
      operation_command "$@"
      ;;
    *)
      pf_core_error "Unknown command: $command"
      usage >&2
      return "$PF_EXIT_ARGUMENTS"
      ;;
  esac
}
main "$@"
