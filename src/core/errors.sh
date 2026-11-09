#!/usr/bin/env bash

PF_EXIT_SUCCESS=0
PF_EXIT_GENERAL=1
PF_EXIT_ARGUMENTS=2
PF_EXIT_ENVIRONMENT=3
PF_EXIT_MODULE=4
PF_EXIT_IMAGE=5
PF_EXIT_STORAGE=6
PF_EXIT_PROXMOX=7
PF_EXIT_CLOUD_INIT=8
PF_EXIT_ROLLBACK=9
PF_EXIT_CONFLICT=10

pf_core_set_error() {
  local code="$1"
  shift
  [[ "$code" =~ ^[0-9]+$ ]] || code="$PF_EXIT_GENERAL"
  PF_CORE_LAST_ERROR_CODE="$code"
  pf_core_error "$*"
  return 0
}

pf_core_fail() {
  local code="$1"
  shift
  pf_core_set_error "$code" "$*"
  return "$code"
}
