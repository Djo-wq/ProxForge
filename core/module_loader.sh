#!/usr/bin/env bash

PF_CORE_DISTRIBUTIONS_DIR="${PF_CORE_DISTRIBUTIONS_DIR:-${PF_CORE_ROOT}/distributions}"

pf_core_check_module_permissions() {
  local directory="$1" module_file="$2" path uid mode
  [[ -d "$PF_CORE_DISTRIBUTIONS_DIR" && ! -L "$PF_CORE_DISTRIBUTIONS_DIR" &&
     -d "$directory" && ! -L "$directory" &&
     -f "$module_file" && ! -L "$module_file" ]] || return 1
  [[ "${PF_CORE_TEST_MODE:-0}" == "1" ]] && return 0

  for path in "$PF_CORE_DISTRIBUTIONS_DIR" "$directory" "$module_file"; do
    uid=$(stat -c '%u' "$path") || return 1
    [[ "$uid" == "0" ]] || {
      pf_core_error "Untrusted module path owner (must be root): $path"
      return 1
    }
    mode=$(stat -c '%a' "$path") || return 1
    (( (8#$mode & 0022) == 0 )) || {
      pf_core_error "Untrusted module permissions (group/world writable): $path"
      return 1
    }
  done
}

pf_core_module_call() {
  local function_name="$1" result_required="$2"
  shift 2
  local output_file status
  [[ -n "${PF_CORE_LOADED_MODULE:-}" ]] || {
    pf_core_error "No distribution module is loaded."
    return 1
  }
  declare -F "$function_name" >/dev/null || {
    pf_core_error "Module function is missing: $function_name"
    return 1
  }

  output_file=$(mktemp "${TMPDIR:-/tmp}/proxforge-module-output.XXXXXX") || return 1
  PF_MODULE_RESULT_JSON=""
  if "$function_name" "$@" > "$output_file"; then status=0; else status=$?; fi
  if [[ -s "$output_file" ]]; then
    pf_core_error "Module function wrote to standard output: $function_name"
    rm -f -- "$output_file"
    return 1
  fi
  rm -f -- "$output_file"
  if (( status != 0 )); then
    pf_core_error "Module function failed ($status): $function_name"
    return "$status"
  fi
  if [[ "$result_required" == "1" ]] && ! pf_core_validate_module_result "$function_name" "$PF_MODULE_RESULT_JSON"; then
    pf_core_error "Module returned invalid result JSON: $function_name"
    PF_MODULE_RESULT_JSON=""
    return 1
  fi
}

pf_core_module_load() {
  local module_id="$1" module_dir module_file source_output status
  pf_core_is_safe_id "$module_id" || {
    pf_core_error "Invalid distribution identifier: $module_id"
    return 1
  }
  if [[ -n "${PF_CORE_LOADED_MODULE:-}" ]]; then
    pf_core_error "A module is already loaded for this process: $PF_CORE_LOADED_MODULE"
    return 1
  fi

  module_dir="${PF_CORE_DISTRIBUTIONS_DIR}/${module_id}"
  module_file="${module_dir}/module.sh"
  if ! pf_core_check_module_permissions "$module_dir" "$module_file"; then
    pf_core_error "Module file is missing or does not meet trust requirements: $module_file"
    return 1
  fi

  # Remove leftovers from a previously rejected load before sourcing a new module.
  unset PF_MODULE_API_VERSION PF_MODULE_ID PF_MODULE_NAME PF_MODULE_FAMILY
  unset PF_MODULE_VERSION PF_MODULE_ARCHES PF_MODULE_RESULT_JSON
  unset -f pf_distro_init pf_distro_list_releases pf_distro_resolve_release
  unset -f pf_distro_get_image pf_distro_validate_image

  source_output=$(mktemp "${TMPDIR:-/tmp}/proxforge-module-source.XXXXXX") || return 1
  if source "$module_file" > "$source_output"; then status=0; else status=$?; fi
  if [[ -s "$source_output" ]]; then
    pf_core_error "Module emitted standard output while being loaded: $module_id"
    rm -f -- "$source_output"
    return 1
  fi
  rm -f -- "$source_output"
  (( status == 0 )) || {
    pf_core_error "Could not load module: $module_id"
    return 1
  }

  if ! pf_core_validate_module_metadata "$module_id"; then
    pf_core_error "Module metadata is invalid: $module_id"
    return 1
  fi
  local required_function
  for required_function in pf_distro_init pf_distro_list_releases pf_distro_resolve_release pf_distro_get_image pf_distro_validate_image; do
    declare -F "$required_function" >/dev/null || {
      pf_core_error "Module $module_id is missing required function: $required_function"
      return 1
    }
  done

  PF_CORE_LOADED_MODULE="$module_id"
  if ! pf_core_module_call pf_distro_init 0; then
    PF_CORE_LOADED_MODULE=""
    return 1
  fi
  pf_core_info "Loaded distribution module: $module_id ($PF_MODULE_VERSION)"
}
