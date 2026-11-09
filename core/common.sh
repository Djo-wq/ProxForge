#!/usr/bin/env bash

PF_CORE_VERSION="1.0.0"
PF_CORE_MODULE_API_VERSION="1"
PF_CORE_CONFIG_SCHEMA_VERSION=1
PF_CORE_PROFILE_SCHEMA_VERSION=1
PF_CORE_LOG_LEVEL="INFO"
PF_CORE_LOADED_MODULE=""
PF_CORE_MODULE_METADATA_JSON="{}"
PF_CORE_PROFILE_JSON="{}"
PF_CORE_PROFILES_JSON="[]"
PF_CORE_CONFIG_JSON="{}"
PF_CORE_LAST_ERROR_CODE=0

pf_core_log() {
  local level="${1:-INFO}"
  shift || true
  local message="$*"
  local configured="${PF_CORE_LOG_LEVEL:-INFO}"
  local current_rank configured_rank
  case "$level" in
    DEBUG) current_rank=0 ;;
    INFO) current_rank=1 ;;
    WARN) current_rank=2 ;;
    ERROR) current_rank=3 ;;
    *) level="INFO"; current_rank=1 ;;
  esac
  case "$configured" in
    DEBUG) configured_rank=0 ;;
    INFO) configured_rank=1 ;;
    WARN) configured_rank=2 ;;
    ERROR) configured_rank=3 ;;
    *) configured_rank=1 ;;
  esac
  (( current_rank < configured_rank )) && return 0
  printf '[%s] %s\n' "$level" "$message" >&2
}

pf_core_info() { pf_core_log INFO "$@"; }
pf_core_warn() { pf_core_log WARN "$@"; }
pf_core_debug() { pf_core_log DEBUG "$@"; }
pf_core_error() { pf_core_log ERROR "$@"; }

pf_core_require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || {
    pf_core_error "Required command not found: $command_name"
    return 1
  }
}

pf_core_is_safe_id() {
  [[ "${1:-}" =~ ^[a-z][a-z0-9-]{1,31}$ ]]
}
