#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/core/bootstrap.sh"

usage() {
  cat <<'USAGE'
ProxForge — Proxmox VM deployment engine

Global options:
  --config FILE             Use an explicit JSON configuration file
  --help, -h                Show this help
  --version                 Show ProxForge and Module API versions

Commands:
  doctor
  version
  help
  profile list | show <profile>
  module list | show <distribution> | releases <distribution>
  module validate <distribution> | image <distribution> <release|stable|latest>
  config show | path | validate [FILE]
  pve doctor | nodes | storages | bridges | vmid next
  image cache list
  deploy <distribution> <release> <profile> <storage> <bridge> [--name NAME] [--vmid ID|auto]
  operation list | show <uuid> | reconcile <uuid> | rollback <uuid> | resume <uuid>
  completion bash

All inspection commands emit JSON. Module inspection never downloads an image.
VM creation is only performed by the explicit deploy command.
Official-TLS checksums remain disabled unless explicitly enabled in config.
USAGE
}

usage_profile() { printf 'Usage: proxforge.sh profile {list|show <profile>}\n'; }
usage_module() { printf 'Usage: proxforge.sh module {list|show <id>|releases <id>|validate <id>|image <id> <release>}\n'; }
usage_config() { printf 'Usage: proxforge.sh config {show|path|validate [FILE]}\n'; }
usage_pve() { printf 'Usage: proxforge.sh pve {doctor|nodes|storages|bridges|vmid next}\n'; }
usage_deploy() { printf 'Usage: proxforge.sh deploy <distribution> <release> <profile> <storage> <bridge> [--name NAME] [--vmid ID|auto]\n'; }
usage_operation() { printf 'Usage: proxforge.sh operation {list|show <uuid>|reconcile <uuid>|rollback <uuid>|resume <uuid>}\n'; }

doctor_command() {
  local command_name available failed=0 root_ok
  local checks='[]' modules_json
  local -a commands=(jq curl flock qemu-img sha256sum sha512sum gpgv qm pvesh pvesm pveversion ip)
  local i
  root_ok=false
  [[ "$EUID" == "0" ]] && root_ok=true
  checks=$(jq -cn --argjson available "$root_ok" \
    '[{name:"root_privileges",available:$available,required:true}]') || return 1
  [[ "$root_ok" == "true" ]] || failed=$((failed + 1))
  for i in "${!commands[@]}"; do
    command_name="${commands[$i]}"
    available=false
    command -v "$command_name" >/dev/null 2>&1 && available=true
    checks=$(jq -c --arg name "$command_name" --argjson available "$available" \
      '. + [{name:$name,available:$available,required:true}]' <<< "$checks") || return 1
    [[ "$available" == "true" ]] || failed=$((failed + 1))
  done
  modules_json=$(pf_core_distributions_list) || return 1
  jq -cn --arg version "$PF_CORE_VERSION" \
    --arg api "$PF_CORE_MODULE_API_VERSION" \
    --arg root "$PF_CORE_ROOT" \
    --arg config_source "${PF_CORE_CONFIG_SOURCE_FILE:-}" \
    --argjson checks "$checks" --argjson modules "$modules_json" \
    --argjson failures "$failed" '{
      proxforge_version:$version,module_api_version:$api,installation_root:$root,
      configuration_source:$config_source,checks:$checks,modules:$modules,
      ready_for_deployment:($failures == 0),failed_required_checks:$failures
    }'
  (( failed == 0 ))
}

profile_command() {
  case "${2:-}" in
    list)
      (( $# == 2 )) || { usage_profile >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_core_profiles_list || return 1
      jq . <<< "$PF_CORE_PROFILES_JSON" ;;
    show)
      (( $# == 3 )) || { usage_profile >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_core_profile_load "$3" || return 1
      jq . <<< "$PF_CORE_PROFILE_JSON" ;;
    --help|-h|help) usage_profile ;;
    *) usage_profile >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}

module_command() {
  local subcommand="${2:-}" module_id selector releases metadata release_json version
  local descriptor policy_allowed output='[]' method
  case "$subcommand" in
    list)
      (( $# == 2 )) || { usage_module >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_core_distributions_list ;;
    show|releases)
      (( $# == 3 )) || { usage_module >&2; return "$PF_EXIT_ARGUMENTS"; }
      module_id="$3"
      pf_core_module_load "$module_id" || return 1
      pf_core_module_call pf_distro_list_releases 1 || return 1
      releases="$PF_MODULE_RESULT_JSON"
      if [[ "$subcommand" == "releases" ]]; then
        jq . <<< "$releases"
      else
        jq -cn --argjson metadata "$PF_CORE_MODULE_METADATA_JSON" \
          --argjson releases "$releases" '{metadata:$metadata,releases:$releases}'
      fi ;;
    validate)
      (( $# == 3 )) || { usage_module >&2; return "$PF_EXIT_ARGUMENTS"; }
      module_id="$3"
      pf_core_module_load "$module_id" || return 1
      metadata="$PF_CORE_MODULE_METADATA_JSON"
      pf_core_module_call pf_distro_list_releases 1 || return 1
      releases="$PF_MODULE_RESULT_JSON"
      while IFS= read -r release_json; do
        [[ -n "$release_json" ]] || continue
        [[ "$(jq -r '.channel' <<< "$release_json")" == "stable" ]] || continue
        case "$(jq -r '.status' <<< "$release_json")" in supported|maintenance) ;; *) continue ;; esac
        version=$(jq -r '.version' <<< "$release_json") || return 1
        pf_core_module_call pf_distro_get_image 1 "$version" "${PF_MODULE_ARCHES[0]}" || return 1
        descriptor="$PF_MODULE_RESULT_JSON"
        method=$(jq -r '.verification.method' <<< "$descriptor") || return 1
        policy_allowed=true
        if [[ "$method" == "official-tls-checksum" &&
              "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" != "true" ]]; then
          policy_allowed=false
        fi
        output=$(jq -cn --argjson current "$release_json" --argjson descriptor "$descriptor" \
          --argjson allowed "$policy_allowed" \
          '. + [{release:$current,image_descriptor_valid:true,policy_allowed:$allowed,verification_method:$descriptor.verification.method}]' \
          <<< "$output") || return 1
      done < <(jq -c '.[]' <<< "$releases")
      jq -cn --argjson metadata "$metadata" --argjson releases "$output" \
        '{valid:true,metadata:$metadata,releases:$releases}' ;;
    image)
      (( $# == 4 )) || { usage_module >&2; return "$PF_EXIT_ARGUMENTS"; }
      module_id="$3"; selector="$4"
      pf_core_module_load "$module_id" || return 1
      pf_core_module_call pf_distro_resolve_release 1 "$selector" || return 1
      release_json="$PF_MODULE_RESULT_JSON"
      version=$(jq -r '.version' <<< "$release_json") || return 1
      pf_core_module_call pf_distro_get_image 1 "$version" "${PF_MODULE_ARCHES[0]}" || return 1
      descriptor="$PF_MODULE_RESULT_JSON"
      method=$(jq -r '.verification.method' <<< "$descriptor") || return 1
      policy_allowed=true
      if [[ "$method" == "official-tls-checksum" &&
            "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" != "true" ]]; then
        policy_allowed=false
      fi
      jq -cn --argjson release "$release_json" --argjson image "$descriptor" \
        --argjson policy_allowed "$policy_allowed" '{
          release:$release,image_descriptor:$image,
          policy:{acquisition_allowed:$policy_allowed,
            reason:(if $policy_allowed then null else "allow_official_tls_checksum must be explicitly enabled" end)}
        }' ;;
    --help|-h|help) usage_module ;;
    *) usage_module >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}

config_command() {
  case "${2:-}" in
    show)
      (( $# == 2 )) || { usage_config >&2; return "$PF_EXIT_ARGUMENTS"; }
      jq . <<< "$PF_CORE_CONFIG_JSON" ;;
    path)
      (( $# == 2 )) || { usage_config >&2; return "$PF_EXIT_ARGUMENTS"; }
      jq -cn --arg source "${PF_CORE_CONFIG_SOURCE_FILE:-}" '{source_file:$source}' ;;
    validate)
      (( $# <= 3 )) || { usage_config >&2; return "$PF_EXIT_ARGUMENTS"; }
      if (( $# == 3 )); then pf_core_config_load "$3" || return 1
      else pf_core_validate_config_json "$PF_CORE_CONFIG_JSON" || return 1; fi
      jq -cn --arg source "${PF_CORE_CONFIG_SOURCE_FILE:-}" \
        --argjson config "$PF_CORE_CONFIG_JSON" '{valid:true,source_file:$source,config:$config}' ;;
    --help|-h|help) usage_config ;;
    *) usage_config >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}

pve_command() {
  local subcommand="${2:-doctor}"
  case "$subcommand" in --help|-h|help) usage_pve; return 0 ;; esac
  pf_pve_init || return $?
  case "$subcommand" in
    doctor)
      (( $# == 2 )) || { usage_pve >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_pve_refresh_inventory || return 1
      jq . <<< "$PF_PVE_INVENTORY_JSON" ;;
    nodes)
      (( $# == 2 )) || { usage_pve >&2; return "$PF_EXIT_ARGUMENTS"; }
      jq . <<< "$PF_PVE_NODES_JSON" ;;
    storages)
      (( $# == 2 )) || { usage_pve >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_pve_refresh_inventory || return 1
      jq . <<< "$PF_PVE_STORAGES_JSON" ;;
    bridges)
      (( $# == 2 )) || { usage_pve >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_pve_refresh_inventory || return 1
      jq . <<< "$PF_PVE_BRIDGES_JSON" ;;
    vmid)
      (( $# == 3 )) && [[ "$3" == "next" ]] || { usage_pve >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_pve_next_vmid || return 1
      printf '%s\n' "$PF_PVE_NEXT_VMID" ;;
    *) usage_pve >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}

image_command() {
  case "${2:-}" in
    cache)
      [[ "${3:-}" == "list" && $# == 3 ]] || {
        printf 'Usage: proxforge.sh image cache list\n' >&2
        return "$PF_EXIT_ARGUMENTS"
      }
      pf_image_cache_list ;;
    --help|-h|help) printf 'Usage: proxforge.sh image cache list\n' ;;
    *) printf 'Usage: proxforge.sh image cache list\n' >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}

deploy_command() {
  local distribution release profile storage bridge name="" vmid=auto
  local positional_name="" positional_vmid="" option_name=false option_vmid=false
  (( $# >= 6 )) || { usage_deploy >&2; return "$PF_EXIT_ARGUMENTS"; }
  distribution="$2"; release="$3"; profile="$4"; storage="$5"; bridge="$6"
  shift 6
  if (( $# > 0 )) && [[ "$1" != --* ]]; then
    (( $# <= 2 )) || { usage_deploy >&2; return "$PF_EXIT_ARGUMENTS"; }
    positional_name="$1"
    if (( $# == 2 )); then positional_vmid="$2"; fi
    name="$positional_name"
    [[ -n "$positional_vmid" ]] && vmid="$positional_vmid"
    shift "$#"
  fi
  while (( $# > 0 )); do
    case "$1" in
      --name)
        (( $# >= 2 )) && [[ "$option_name" == "false" ]] || { usage_deploy >&2; return "$PF_EXIT_ARGUMENTS"; }
        name="$2"; option_name=true; shift 2 ;;
      --vmid)
        (( $# >= 2 )) && [[ "$option_vmid" == "false" ]] || { usage_deploy >&2; return "$PF_EXIT_ARGUMENTS"; }
        vmid="$2"; option_vmid=true; shift 2 ;;
      --help|-h|help) usage_deploy; return 0 ;;
      *) usage_deploy >&2; return "$PF_EXIT_ARGUMENTS" ;;
    esac
  done
  [[ "$vmid" == "auto" || "$vmid" =~ ^[0-9]{3,9}$ ]] || {
    pf_core_error "VMID must be 'auto' or a numeric value between 100 and 999999999."
    return "$PF_EXIT_ARGUMENTS"
  }
  pf_vm_lifecycle_deploy "$distribution" "$release" "$profile" "$storage" "$bridge" "$name" "$vmid"
}

operation_command() {
  case "${2:-}" in
    list)
      (( $# == 2 )) || { usage_operation >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_vm_lifecycle_operation_list ;;
    show)
      (( $# == 3 )) || { usage_operation >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_vm_lifecycle_operation_show "$3" ;;
    reconcile)
      (( $# == 3 )) || { usage_operation >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_vm_lifecycle_reconcile "$3" ;;
    rollback)
      (( $# == 3 )) || { usage_operation >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_operations_rollback_operation "$3" ;;
    resume)
      (( $# == 3 )) || { usage_operation >&2; return "$PF_EXIT_ARGUMENTS"; }
      pf_operations_resume_operation "$3" ;;
    --help|-h|help) usage_operation ;;
    *) usage_operation >&2; return "$PF_EXIT_ARGUMENTS" ;;
  esac
}

completion_bash() {
  cat <<'COMPLETION'
_proxforge_complete() {
  local cur prev words cword
  _init_completion || return
  if [[ $cword -eq 1 ]]; then
    COMPREPLY=( $(compgen -W '--config --help --version doctor version help profile module config pve image deploy operation completion' -- "$cur") )
    return
  fi
  case "${words[1]}" in
    profile) COMPREPLY=( $(compgen -W 'list show --help' -- "$cur") ) ;;
    module) COMPREPLY=( $(compgen -W 'list show releases validate image --help' -- "$cur") ) ;;
    config) COMPREPLY=( $(compgen -W 'show path validate --help' -- "$cur") ) ;;
    pve) COMPREPLY=( $(compgen -W 'doctor nodes storages bridges vmid --help' -- "$cur") ) ;;
    image) COMPREPLY=( $(compgen -W 'cache --help' -- "$cur") ) ;;
    operation) COMPREPLY=( $(compgen -W 'list show reconcile rollback resume --help' -- "$cur") ) ;;
    deploy)
      if [[ $cur == --* ]]; then COMPREPLY=( $(compgen -W '--name --vmid --help' -- "$cur") ); fi
      ;;
    completion) COMPREPLY=( $(compgen -W 'bash' -- "$cur") ) ;;
  esac
}
complete -F _proxforge_complete proxforge.sh
COMPLETION
}

main() {
  local config_file="" command=help version_shortcut=false
  while (( $# > 0 )); do
    case "$1" in
      --config)
        (( $# >= 2 )) || { pf_core_error "--config requires a file path."; return "$PF_EXIT_ARGUMENTS"; }
        config_file="$2"; shift 2 ;;
      --config=*)
        config_file="${1#*=}"
        [[ -n "$config_file" ]] || { pf_core_error "--config requires a file path."; return "$PF_EXIT_ARGUMENTS"; }
        shift ;;
      --help|-h) usage; return 0 ;;
      --version)
        command=version
        version_shortcut=true
        shift
        break ;;
      --) shift; break ;;
      -*)
        pf_core_error "Unknown global option: $1"
        usage >&2
        return "$PF_EXIT_ARGUMENTS" ;;
      *) break ;;
    esac
  done

  if [[ -n "$config_file" ]]; then PF_CORE_CONFIG_FILE="$config_file"; fi
  (( $# >= 1 )) && command="$1"
  pf_core_init || return $?

  case "$command" in
    version)
      if [[ "$version_shortcut" == "true" ]]; then (( $# == 0 )) || return "$PF_EXIT_ARGUMENTS"
      else (( $# == 1 )) || return "$PF_EXIT_ARGUMENTS"; fi
      printf 'ProxForge %s (Module API %s)\n' "$PF_CORE_VERSION" "$PF_CORE_MODULE_API_VERSION" ;;
    help|-h|--help)
      (( $# == 1 )) || return "$PF_EXIT_ARGUMENTS"
      usage ;;
    doctor)
      (( $# == 1 )) || return "$PF_EXIT_ARGUMENTS"
      doctor_command ;;
    profile) profile_command "$@" ;;
    module) module_command "$@" ;;
    config) config_command "$@" ;;
    pve) pve_command "$@" ;;
    image) image_command "$@" ;;
    deploy) deploy_command "$@" ;;
    operation) operation_command "$@" ;;
    completion)
      [[ $# == 2 && "$2" == "bash" ]] || {
        printf 'Usage: proxforge.sh completion bash\n' >&2
        return "$PF_EXIT_ARGUMENTS"
      }
      completion_bash ;;
    *)
      pf_core_error "Unknown command: $command"
      usage >&2
      return "$PF_EXIT_ARGUMENTS" ;;
  esac
}
main "$@"
