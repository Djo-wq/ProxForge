#!/usr/bin/env bash

pf_core_validate_config_json() {
  local json="$1"
  jq -e '
    type == "object" and
    (keys - ["schema_version", "default_profile", "rollback_mode", "start_vm",
             "allow_official_tls_checksum", "image_cache_dir", "tmp_dir",
             "state_dir", "log_dir", "log_level"] | length == 0) and
    .schema_version == 1 and
    (.default_profile | type == "string" and test("^[a-z][a-z0-9-]{1,31}$")) and
    (.rollback_mode == "auto" or .rollback_mode == "keep") and
    (.start_vm | type == "boolean") and
    (.allow_official_tls_checksum | type == "boolean") and
    (.image_cache_dir | type == "string" and startswith("/")) and
    (.tmp_dir | type == "string" and startswith("/")) and
    (.state_dir | type == "string" and startswith("/")) and
    (.log_dir | type == "string" and startswith("/")) and
    (.log_level == "DEBUG" or .log_level == "INFO" or .log_level == "WARN" or .log_level == "ERROR")
  ' <<< "$json" >/dev/null
}

pf_core_validate_profile_json() {
  local json="$1"
  jq -e '
    type == "object" and
    (keys - ["schema_version", "id", "name", "description", "cpu_cores", "memory_mb",
             "disk_gb", "machine", "firmware", "scsi_controller", "network_model",
             "agent_enabled", "secure_boot"] | length == 0) and
    .schema_version == 1 and
    (.id | type == "string" and test("^[a-z][a-z0-9-]{1,31}$")) and
    (.name | type == "string" and length > 0 and length <= 80) and
    (.description | type == "string" and length <= 500) and
    (.cpu_cores | type == "number" and floor == . and . >= 1 and . <= 256) and
    (.memory_mb | type == "number" and floor == . and . >= 128 and . <= 4194304) and
    (.disk_gb | type == "number" and floor == . and . >= 1 and . <= 65536) and
    .machine == "q35" and .firmware == "ovmf" and
    .scsi_controller == "virtio-scsi-pci" and .network_model == "virtio" and
    (.agent_enabled | type == "boolean") and (.secure_boot | type == "boolean")
  ' <<< "$json" >/dev/null
}

pf_core_validate_module_metadata() {
  local expected_id="$1"
  local arches_json metadata_json arch
  pf_core_is_safe_id "$expected_id" || return 1
  [[ "${PF_MODULE_API_VERSION:-}" == "$PF_CORE_MODULE_API_VERSION" ]] || return 1
  [[ "${PF_MODULE_ID:-}" == "$expected_id" ]] || return 1
  [[ -n "${PF_MODULE_NAME:-}" && ${#PF_MODULE_NAME} -le 80 ]] || return 1
  [[ "${PF_MODULE_FAMILY:-}" == "redhat" || "${PF_MODULE_FAMILY:-}" == "debian" ]] || return 1
  [[ "${PF_MODULE_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || return 1
  declare -p PF_MODULE_ARCHES 2>/dev/null | grep -q '^declare -a PF_MODULE_ARCHES=' || return 1
  (( ${#PF_MODULE_ARCHES[@]} > 0 )) || return 1
  for arch in "${PF_MODULE_ARCHES[@]}"; do
    [[ "$arch" == "x86_64" ]] || return 1
  done
  arches_json=$(printf '%s\n' "${PF_MODULE_ARCHES[@]}" | jq -R . | jq -cs .) || return 1
  metadata_json=$(jq -cn \
    --arg api_version "$PF_MODULE_API_VERSION" --arg id "$PF_MODULE_ID" \
    --arg name "$PF_MODULE_NAME" --arg family "$PF_MODULE_FAMILY" \
    --arg version "$PF_MODULE_VERSION" --argjson architectures "$arches_json" \
    '{api_version:$api_version,id:$id,name:$name,family:$family,version:$version,architectures:$architectures}') || return 1
  jq -e '
    type == "object" and
    (keys - ["api_version", "id", "name", "family", "version", "architectures"] | length == 0) and
    .api_version == "1" and
    (.id | type == "string" and test("^[a-z][a-z0-9-]{1,31}$")) and
    (.name | type == "string" and length > 0 and length <= 80) and
    (.family == "redhat" or .family == "debian") and
    (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$")) and
    (.architectures | type == "array" and length > 0 and length == (unique | length) and all(.[]; . == "x86_64"))
  ' <<< "$metadata_json" >/dev/null || return 1
  PF_CORE_MODULE_METADATA_JSON="$metadata_json"
}

pf_core_validate_module_result() {
  local function_name="$1" json="$2"
  jq -e . >/dev/null 2>&1 <<< "$json" || return 1
  case "$function_name" in
    pf_distro_list_releases)
      jq -e '
        type == "array" and length > 0 and
        all(.[]; type == "object" and
          (keys - ["version", "channel", "status", "release_date", "support_lifecycle"] | length == 0) and
          (.version | type == "string" and length > 0) and
          (.channel == "stable" or .channel == "testing" or .channel == "beta" or .channel == "rawhide" or .channel == "archived") and
          (.status == "supported" or .status == "maintenance" or .status == "eol" or .status == "archived" or .status == "unknown") and
          ((has("release_date") | not) or (.release_date | type == "string")) and
          ((has("support_lifecycle") | not) or (.support_lifecycle | type == "object")))
      ' <<< "$json" >/dev/null
      ;;
    pf_distro_resolve_release)
      jq -e '
        type == "object" and
        (keys - ["version", "channel", "status", "release_date", "support_lifecycle"] | length == 0) and
        (.version | type == "string" and length > 0) and
        (.channel == "stable" or .channel == "testing" or .channel == "beta" or .channel == "rawhide" or .channel == "archived") and
        (.status == "supported" or .status == "maintenance" or .status == "eol" or .status == "archived" or .status == "unknown") and
        ((has("release_date") | not) or (.release_date | type == "string")) and
        ((has("support_lifecycle") | not) or (.support_lifecycle | type == "object"))
      ' <<< "$json" >/dev/null
      ;;
    pf_distro_get_image)
      jq -e '
        type == "object" and
        (keys - ["url", "filename", "allowed_hosts", "download_format", "archive_format", "disk_format", "architecture", "release", "checksum", "signature", "verification", "cloud_init"] | length == 0) and
        (.url | type == "string" and startswith("https://") and ((capture("^https://(?<authority>[^/?#]+)").authority | contains("@")) | not)) and
        (.filename | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
        (.allowed_hosts | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9.-]+$"))) and
        .download_format == "file" and .archive_format == "none" and
        (.disk_format == "qcow2" or .disk_format == "raw") and .architecture == "x86_64" and
        (.release | type == "string" and length > 0) and
        (.checksum | type == "object" and (keys - ["url", "algorithm", "filename"] | length == 0) and
          (.url | type == "string" and startswith("https://") and ((capture("^https://(?<authority>[^/?#]+)").authority | contains("@")) | not)) and
          (.algorithm == "sha256" or .algorithm == "sha512") and
          (.filename | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$"))) and
        (.signature == null or (.signature | type == "object" and (keys - ["url", "format", "keyring_id"] | length == 0) and
          (.url | type == "string" and startswith("https://") and ((capture("^https://(?<authority>[^/?#]+)").authority | contains("@")) | not)) and
          .format == "openpgp" and (.keyring_id | type == "string" and length > 0))) and
        (.verification | type == "object" and (keys - ["method", "trust_level"] | length == 0) and
          ((.method == "signed-checksum" and .trust_level == "signed" and .signature != null) or
           (.method == "official-tls-checksum" and .trust_level == "official_tls"))) and
        (.cloud_init | type == "object" and (keys - ["status", "datasource"] | length == 0) and
          (.status == "verified" or .status == "unverified" or .status == "unsupported") and
          ((has("datasource") | not) or (.datasource | type == "string")))
      ' <<< "$json" >/dev/null || return 1
      local image_host checksum_host signature_host
      image_host=$(jq -r '.url | capture("^https://(?<host>[^/:?#@]+)").host' <<< "$json") || return 1
      checksum_host=$(jq -r '.checksum.url | capture("^https://(?<host>[^/:?#@]+)").host' <<< "$json") || return 1
      jq -e --arg host "$image_host" --arg checksum_host "$checksum_host" \
        '.allowed_hosts | (index($host) != null) and (index($checksum_host) != null)' <<< "$json" >/dev/null || return 1
      if [[ "$(jq -r '.signature == null' <<< "$json")" == "false" ]]; then
        signature_host=$(jq -r '.signature.url | capture("^https://(?<host>[^/:?#@]+)").host' <<< "$json") || return 1
        jq -e --arg host "$signature_host" '.allowed_hosts | index($host) != null' <<< "$json" >/dev/null || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}
