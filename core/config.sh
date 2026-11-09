#!/usr/bin/env bash

pf_core_config_load() {
  local override_file="${1:-}"
  local defaults_file="${PF_CORE_ROOT}/config/defaults.json"
  local merged_json

  [[ -r "$defaults_file" ]] || {
    pf_core_error "Default configuration is not readable: $defaults_file"
    return 1
  }
  jq -e . "$defaults_file" >/dev/null 2>&1 || {
    pf_core_error "Default configuration is not valid JSON: $defaults_file"
    return 1
  }

  if [[ -z "$override_file" ]]; then
    if [[ -n "${PF_CORE_CONFIG_FILE:-}" ]]; then
      override_file="$PF_CORE_CONFIG_FILE"
    elif [[ -r /etc/proxforge/config.json ]]; then
      override_file="/etc/proxforge/config.json"
    fi
  fi

  if [[ -n "$override_file" ]]; then
    [[ -f "$override_file" && ! -L "$override_file" && -r "$override_file" ]] || {
      pf_core_error "Configuration file is missing, is a symlink or is not readable: $override_file"
      return 1
    }
    jq -e . "$override_file" >/dev/null 2>&1 || {
      pf_core_error "Configuration file is not valid JSON: $override_file"
      return 1
    }
    merged_json=$(jq -s '.[0] + .[1]' "$defaults_file" "$override_file") || return 1
  else
    merged_json=$(jq -c . "$defaults_file") || return 1
  fi

  if ! pf_core_validate_config_json "$merged_json"; then
    pf_core_error "Configuration contains unknown keys or invalid values."
    return 1
  fi
  PF_CORE_CONFIG_JSON="$merged_json"
  PF_CORE_LOG_LEVEL=$(jq -r '.log_level' <<< "$merged_json")
}
