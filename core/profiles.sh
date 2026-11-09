#!/usr/bin/env bash

PF_CORE_PROFILES_DIR="${PF_CORE_PROFILES_DIR:-${PF_CORE_ROOT}/profiles}"

pf_core_profiles_list() {
  local file profile_id profile_json nullglob_was_set=0
  local -a profile_files=() profile_entries=()
  [[ -d "$PF_CORE_PROFILES_DIR" ]] || {
    pf_core_error "Profiles directory is missing: $PF_CORE_PROFILES_DIR"
    return 1
  }
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  profile_files=("$PF_CORE_PROFILES_DIR"/*.json)
  (( nullglob_was_set == 1 )) || shopt -u nullglob

  for file in "${profile_files[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    profile_id=$(basename -- "$file" .json)
    pf_core_is_safe_id "$profile_id" || continue
    profile_json=$(<"$file") || return 1
    if ! pf_core_validate_profile_json "$profile_json"; then
      pf_core_error "Invalid profile file: $file"
      return 1
    fi
    profile_entries+=("$profile_id")
  done
  PF_CORE_PROFILES_JSON=$(printf '%s\n' "${profile_entries[@]}" | jq -R . | jq -cs .) || return 1
}

pf_core_profile_load() {
  local profile_id="$1" profile_file profile_json file_id
  pf_core_is_safe_id "$profile_id" || {
    pf_core_error "Invalid profile identifier: $profile_id"
    return 1
  }
  profile_file="${PF_CORE_PROFILES_DIR}/${profile_id}.json"
  [[ -f "$profile_file" && ! -L "$profile_file" && -r "$profile_file" ]] || {
    pf_core_error "Profile not found or not readable: $profile_id"
    return 1
  }
  profile_json=$(<"$profile_file") || return 1
  if ! pf_core_validate_profile_json "$profile_json"; then
    pf_core_error "Profile does not match the profile contract: $profile_id"
    return 1
  fi
  file_id=$(jq -r '.id' <<< "$profile_json") || return 1
  [[ "$file_id" == "$profile_id" ]] || {
    pf_core_error "Profile ID does not match filename: $profile_id"
    return 1
  }
  PF_CORE_PROFILE_JSON="$profile_json"
}
