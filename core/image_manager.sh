#!/usr/bin/env bash
# ProxForge Image Manager. Sourced by Core; no work is performed at source time.

PF_IMAGE_CACHE_DIR=""
PF_IMAGE_TRUST_ROOT=""
PF_IMAGE_TRUST_FILE=""
PF_IMAGE_PATH=""
PF_IMAGE_METADATA_JSON="{}"
PF_IMAGE_CACHE_HIT=false
PF_IMAGE_MAX_REDIRECTS=5
PF_IMAGE_CHECKSUM_MAX_BYTES=8388608

pf_image_error() { pf_core_error "Image Manager: $*"; }

pf_image_safe_token() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ &&
     "${1:-}" != "." && "${1:-}" != ".." ]]
}

pf_image_url_host() {
  local url="${1:-}" host label
  local -a labels=()
  PF_IMAGE_URL_HOST=""
  [[ "$url" =~ ^https://([A-Za-z0-9.-]+)(:443)?(/[^[:space:]#]*)?$ ]] || return 1
  host="${BASH_REMATCH[1],,}"
  [[ "$host" != *..* && "$host" != .* && "$host" != *. ]] || return 1
  IFS='.' read -r -a labels <<< "$host"
  (( ${#labels[@]} > 0 )) || return 1
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  PF_IMAGE_URL_HOST="$host"
}

pf_image_host_is_allowed() {
  local host="$1" allowed_hosts_json="$2"
  jq -e --arg host "$host" 'type == "array" and length > 0 and index($host) != null' \
    <<< "$allowed_hosts_json" >/dev/null
}

pf_image_validate_descriptor() {
  local descriptor_json="$1" url checksum_url signature_url
  local url_host checksum_host signature_host allowed_hosts verification_method

  pf_core_validate_module_result pf_distro_get_image "$descriptor_json" || {
    pf_image_error "Image descriptor does not match the Module API v1 contract."
    return 1
  }

  url=$(jq -r '.url' <<< "$descriptor_json") || return 1
  checksum_url=$(jq -r '.checksum.url' <<< "$descriptor_json") || return 1
  if ! pf_image_url_host "$url"; then
    pf_image_error "Image URL is not a supported HTTPS URL."
    return 1
  fi
  url_host="$PF_IMAGE_URL_HOST"
  if ! pf_image_url_host "$checksum_url"; then
    pf_image_error "Checksum URL is not a supported HTTPS URL."
    return 1
  fi
  checksum_host="$PF_IMAGE_URL_HOST"
  allowed_hosts=$(jq -c '.allowed_hosts' <<< "$descriptor_json") || return 1

  pf_image_host_is_allowed "$url_host" "$allowed_hosts" || {
    pf_image_error "Image URL host is not in allowed_hosts: $url_host"
    return 1
  }
  pf_image_host_is_allowed "$checksum_host" "$allowed_hosts" || {
    pf_image_error "Checksum URL host is not in allowed_hosts: $checksum_host"
    return 1
  }

  if [[ "$(jq -r '.signature == null' <<< "$descriptor_json")" == "false" ]]; then
    signature_url=$(jq -r '.signature.url' <<< "$descriptor_json") || return 1
    if ! pf_image_url_host "$signature_url"; then
      pf_image_error "Signature URL is not a supported HTTPS URL."
      return 1
    fi
    signature_host="$PF_IMAGE_URL_HOST"
    pf_image_host_is_allowed "$signature_host" "$allowed_hosts" || {
      pf_image_error "Signature URL host is not in allowed_hosts: $signature_host"
      return 1
    }
  fi

  verification_method=$(jq -r '.verification.method' <<< "$descriptor_json") || return 1
  case "$verification_method" in
    signed-checksum)
      [[ "$(jq -r '.signature == null' <<< "$descriptor_json")" == "false" ]] || {
        pf_image_error "signed-checksum requires a detached signature."
        return 1
      }
      ;;
    official-tls-checksum)
      [[ "$(jq -r '.signature == null' <<< "$descriptor_json")" == "true" ]] || {
        pf_image_error "official-tls-checksum must not carry an ambiguous detached signature."
        return 1
      }
      [[ "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" == "true" ]] || {
        pf_image_error "Official-TLS checksums are disabled by policy."
        return 1
      }
      ;;
    *)
      pf_image_error "Unsupported verification method: $verification_method"
      return 1
      ;;
  esac
}

pf_image_check_cache_path_components() {
  local component current="" uid mode
  local -a components=()
  [[ "$PF_IMAGE_CACHE_DIR" == /* && "$PF_IMAGE_CACHE_DIR" != *//* ]] || return 1
  [[ "$PF_IMAGE_CACHE_DIR" != *"/../"* && "$PF_IMAGE_CACHE_DIR" != *"/./"* &&
     "$PF_IMAGE_CACHE_DIR" != */.. && "$PF_IMAGE_CACHE_DIR" != */. ]] || return 1
  IFS='/' read -r -a components <<< "${PF_IMAGE_CACHE_DIR#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current}/${component}"
    [[ ! -L "$current" ]] || {
      pf_image_error "Cache path contains a symbolic link: $current"
      return 1
    }
    [[ ! -e "$current" || -d "$current" ]] || {
      pf_image_error "Cache path component is not a directory: $current"
      return 1
    }
    if [[ -d "$current" && ! ("${PF_IMAGE_TEST_MODE:-0}" == "1" && "$EUID" != "0") ]]; then
      uid=$(stat -c '%u' "$current") || return 1
      [[ "$uid" == "0" ]] || {
        pf_image_error "Cache path parent must be root-owned: $current"
        return 1
      }
      mode=$(stat -c '%a' "$current") || return 1
      if (( (8#$mode & 0022) != 0 )); then
        (( (8#$mode & 01000) != 0 && uid == 0 )) || {
          pf_image_error "Cache path parent is group/world writable: $current"
          return 1
        }
      fi
    fi
  done
}

pf_image_check_secure_path() {
  local path="$1" expected_type="$2" uid mode
  if [[ "$expected_type" == "directory" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || return 1
  else
    [[ -f "$path" && ! -L "$path" ]] || return 1
  fi

  if [[ "${PF_IMAGE_TEST_MODE:-0}" == "1" && "$EUID" != "0" ]]; then
    uid=$(stat -c '%u' "$path") || return 1
    [[ "$uid" == "$EUID" ]] || return 1
    return 0
  fi

  uid=$(stat -c '%u' "$path") || return 1
  [[ "$uid" == "0" ]] || {
    pf_image_error "Path must be owned by root: $path"
    return 1
  }
  mode=$(stat -c '%a' "$path") || return 1
  (( (8#$mode & 0022) == 0 )) || {
    pf_image_error "Path must not be group/world writable: $path"
    return 1
  }
}

pf_image_init() {
  PF_IMAGE_CACHE_DIR=$(jq -r '.image_cache_dir' <<< "$PF_CORE_CONFIG_JSON") || return 1
  PF_IMAGE_TRUST_ROOT="${PF_IMAGE_TRUST_ROOT:-${PF_CORE_ROOT}/trust}"
  PF_IMAGE_TRUST_FILE="${PF_IMAGE_TRUST_FILE:-${PF_IMAGE_TRUST_ROOT}/keyrings.json}"

  [[ "$PF_IMAGE_CACHE_DIR" == /* && "$PF_IMAGE_CACHE_DIR" != "/" ]] || {
    pf_image_error "image_cache_dir must be an absolute non-root path."
    return 1
  }
  PF_IMAGE_CACHE_DIR="${PF_IMAGE_CACHE_DIR%/}"
  pf_image_check_cache_path_components || {
    pf_image_error "Image cache path contains an untrusted or unsafe component."
    return 1
  }

  local command_name
  for command_name in curl flock sha256sum sha512sum qemu-img stat jq date mktemp awk; do
    pf_core_require_command "$command_name" || return 1
  done

  mkdir -p -m 0750 -- "$PF_IMAGE_CACHE_DIR" "$PF_IMAGE_CACHE_DIR/.locks" "$PF_IMAGE_CACHE_DIR/.staging" || {
    pf_image_error "Could not create image cache directories."
    return 1
  }
  pf_image_check_secure_path "$PF_IMAGE_CACHE_DIR" directory || return 1
  pf_image_check_secure_path "$PF_IMAGE_CACHE_DIR/.locks" directory || return 1
  pf_image_check_secure_path "$PF_IMAGE_CACHE_DIR/.staging" directory || return 1
}

# Download one HTTPS resource without letting curl follow redirects. Every hop
# is inspected and must use an exact hostname in allowed_hosts.
pf_image_download_url() {
  local initial_url="$1" allowed_hosts_json="$2" output_file="$3" max_bytes="$4"
  local headers_file current_url location status_code curl_status hop file_size

  headers_file=$(mktemp "${TMPDIR:-/tmp}/proxforge-http-headers.XXXXXX") || return 1
  current_url="$initial_url"
  hop=0

  while :; do
    if ! pf_image_url_host "$current_url"; then
      pf_image_error "Refusing non-HTTPS, credential-bearing or unsupported URL."
      rm -f -- "$headers_file"
      return 1
    fi
    pf_image_host_is_allowed "$PF_IMAGE_URL_HOST" "$allowed_hosts_json" || {
      pf_image_error "Redirect target is not allow-listed: $PF_IMAGE_URL_HOST"
      rm -f -- "$headers_file"
      return 1
    }

    : > "$headers_file"
    curl_status=0
    status_code=$(curl --silent --show-error \
      --proto '=https' \
      --connect-timeout 30 \
      --max-time "$PF_IMAGE_DOWNLOAD_TIMEOUT" \
      --max-filesize "$max_bytes" \
      --max-redirs 0 \
      --retry 2 \
      --retry-delay 1 \
      --dump-header "$headers_file" \
      --output "$output_file" \
      --write-out '%{http_code}' \
      --url "$current_url") || curl_status=$?

    if (( curl_status != 0 )); then
      pf_image_error "HTTPS transfer failed (curl exit $curl_status): $current_url"
      rm -f -- "$headers_file"
      return 1
    fi

    if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
      file_size=$(stat -c '%s' "$output_file") || {
        rm -f -- "$headers_file"
        return 1
      }
      if (( file_size < 1 || file_size > max_bytes )); then
        pf_image_error "Downloaded resource size is outside the permitted range."
        rm -f -- "$headers_file"
        return 1
      fi
      rm -f -- "$headers_file"
      return 0
    fi

    if [[ "$status_code" =~ ^30[1278]$ ]]; then
      if (( hop >= PF_IMAGE_MAX_REDIRECTS )); then
        pf_image_error "Maximum HTTPS redirect count exceeded."
        rm -f -- "$headers_file"
        return 1
      fi
      location=$(awk 'tolower($1) == "location:" { $1=""; sub(/^[[:space:]]+/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$headers_file")
      [[ -n "$location" && "$location" == https://* ]] || {
        pf_image_error "Redirect must provide an absolute HTTPS Location header."
        rm -f -- "$headers_file"
        return 1
      }
      if ! pf_image_url_host "$location"; then
        pf_image_error "Redirect target URL is invalid."
        rm -f -- "$headers_file"
        return 1
      fi
      pf_image_host_is_allowed "$PF_IMAGE_URL_HOST" "$allowed_hosts_json" || {
        pf_image_error "Redirect target is not allow-listed: $PF_IMAGE_URL_HOST"
        rm -f -- "$headers_file"
        return 1
      }
      current_url="$location"
      ((hop += 1))
      continue
    fi

    pf_image_error "Unexpected HTTP status: $status_code"
    rm -f -- "$headers_file"
    return 1
  done
}

pf_image_verify_signature() {
  local signature_file="$1" checksum_file="$2" keyring_id="$3"
  local keyring_file status_file error_file expected_json fingerprint
  local -a valid_fingerprints=()

  pf_core_is_safe_id "$keyring_id" || {
    pf_image_error "Invalid trusted keyring identifier: $keyring_id"
    return 1
  }
  [[ -r "$PF_IMAGE_TRUST_FILE" && -f "$PF_IMAGE_TRUST_FILE" && ! -L "$PF_IMAGE_TRUST_FILE" ]] || {
    pf_image_error "Trusted keyring registry is missing: $PF_IMAGE_TRUST_FILE"
    return 1
  }
  pf_image_check_secure_path "$PF_IMAGE_TRUST_FILE" file || return 1
  jq -e --arg id "$keyring_id" '
    .schema_version == 1 and (.keyrings | type == "object") and
    (.keyrings[$id] | type == "object" and
      (.fingerprints | type == "array" and length > 0 and
       all(.[]; type == "string" and test("^([A-Fa-f0-9]{40}|[A-Fa-f0-9]{64})$"))))
  ' "$PF_IMAGE_TRUST_FILE" >/dev/null || {
    pf_image_error "No pinned fingerprints configured for keyring: $keyring_id"
    return 1
  }

  keyring_file="${PF_IMAGE_TRUST_ROOT}/keyrings/${keyring_id}.gpg"
  pf_image_check_secure_path "$PF_IMAGE_TRUST_ROOT" directory || return 1
  pf_image_check_secure_path "$PF_IMAGE_TRUST_ROOT/keyrings" directory || return 1
  pf_image_check_secure_path "$keyring_file" file || {
    pf_image_error "Trusted GPG keyring is missing or unsafe: $keyring_file"
    return 1
  }
  pf_core_require_command gpgv || return 1

  status_file=$(mktemp "${TMPDIR:-/tmp}/proxforge-gpg-status.XXXXXX") || return 1
  error_file=$(mktemp "${TMPDIR:-/tmp}/proxforge-gpg-error.XXXXXX") || {
    rm -f -- "$status_file"
    return 1
  }
  if ! gpgv --status-fd 1 --keyring "$keyring_file" "$signature_file" "$checksum_file" >"$status_file" 2>"$error_file"; then
    rm -f -- "$status_file" "$error_file"
    pf_image_error "Detached checksum signature verification failed."
    return 1
  fi

  expected_json=$(jq -c --arg id "$keyring_id" '.keyrings[$id].fingerprints | map(ascii_upcase)' "$PF_IMAGE_TRUST_FILE") || {
    rm -f -- "$status_file" "$error_file"
    return 1
  }
  mapfile -t valid_fingerprints < <(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print toupper($3) }' "$status_file")
  rm -f -- "$status_file" "$error_file"

  for fingerprint in "${valid_fingerprints[@]}"; do
    if jq -e --arg fp "$fingerprint" 'index($fp) != null' <<< "$expected_json" >/dev/null; then
      PF_IMAGE_SIGNATURE_FINGERPRINT="$fingerprint"
      return 0
    fi
  done

  pf_image_error "Signature is valid but its signing fingerprint is not pinned."
  return 1
}

pf_image_read_expected_checksum() {
  local checksum_file="$1" filename="$2" algorithm="$3"
  local -a matches=()
  mapfile -t matches < <(awk -v target="$filename" '
    NF >= 2 {
      name=$2
      sub(/^\*/, "", name)
      if (name == target || name == "./" target) print tolower($1)
    }
  ' "$checksum_file")

  (( ${#matches[@]} == 1 )) || {
    pf_image_error "Checksum file must contain exactly one entry for $filename."
    return 1
  }
  case "$algorithm" in
    sha256) [[ "${matches[0]}" =~ ^[a-f0-9]{64}$ ]] || return 1 ;;
    sha512) [[ "${matches[0]}" =~ ^[a-f0-9]{128}$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  PF_IMAGE_EXPECTED_CHECKSUM="${matches[0]}"
}

pf_image_compute_checksum() {
  local algorithm="$1" image_file="$2" output
  case "$algorithm" in
    sha256) output=$(sha256sum -- "$image_file") || return 1 ;;
    sha512) output=$(sha512sum -- "$image_file") || return 1 ;;
    *) return 1 ;;
  esac
  PF_IMAGE_ACTUAL_CHECKSUM="${output%% *}"
}

pf_image_validate_disk_image() {
  local image_file="$1" expected_format="$2" image_info
  image_info=$(qemu-img info --output=json "$image_file") || {
    pf_image_error "qemu-img could not inspect downloaded image."
    return 1
  }
  jq -e --arg format "$expected_format" '
    type == "object" and .format == $format and
    (.["virtual-size"] | type == "number" and floor == . and . > 0)
  ' <<< "$image_info" >/dev/null || {
    pf_image_error "Detected disk format does not match the module descriptor."
    return 1
  }
  PF_IMAGE_QEMU_INFO_JSON="$image_info"
}

pf_image_metadata_matches() {
  local metadata_file="$1" descriptor_json="$2" distribution="$3" expected_checksum="$4"
  local expected_method expected_trust
  expected_method=$(jq -r '.verification.method' <<< "$descriptor_json") || return 1
  expected_trust=$(jq -r '.verification.trust_level' <<< "$descriptor_json") || return 1

  jq -e \
    --arg distribution "$distribution" \
    --arg release "$(jq -r '.release' <<< "$descriptor_json")" \
    --arg architecture "$(jq -r '.architecture' <<< "$descriptor_json")" \
    --arg source_url "$(jq -r '.url' <<< "$descriptor_json")" \
    --arg filename "$(jq -r '.filename' <<< "$descriptor_json")" \
    --arg disk_format "$(jq -r '.disk_format' <<< "$descriptor_json")" \
    --arg algorithm "$(jq -r '.checksum.algorithm' <<< "$descriptor_json")" \
    --arg checksum "$expected_checksum" \
    --arg method "$expected_method" \
    --arg trust "$expected_trust" '
      type == "object" and
      (keys - ["schema_version","distribution","release","architecture","source_url","filename",
               "download_format","archive_format","disk_format","file_size","checksum_algorithm",
               "checksum_value","verification_method","verification_result","trust_level",
               "verification_date","publication_identifier","cached_at"] | length == 0) and
      .schema_version == 1 and .distribution == $distribution and .release == $release and
      .architecture == $architecture and .source_url == $source_url and .filename == $filename and
      .download_format == "file" and .archive_format == "none" and .disk_format == $disk_format and
      (.file_size | type == "number" and floor == . and . > 0) and
      .checksum_algorithm == $algorithm and .checksum_value == $checksum and
      .verification_method == $method and .verification_result == true and .trust_level == $trust and
      (.verification_date | type == "string" and length >= 20) and
      (.publication_identifier | type == "string" and length > 0) and
      (.cached_at | type == "string" and length >= 20)
    ' "$metadata_file" >/dev/null
}

pf_image_cache_validate() {
  local image_file="$1" metadata_file="$2" descriptor_json="$3" distribution="$4"
  local expected_checksum="$5" algorithm="$6" expected_format="$7"
  local actual_size metadata_size actual_checksum

  [[ -f "$image_file" && ! -L "$image_file" && -f "$metadata_file" && ! -L "$metadata_file" ]] || return 1
  jq -e . "$metadata_file" >/dev/null 2>&1 || return 1
  pf_image_metadata_matches "$metadata_file" "$descriptor_json" "$distribution" "$expected_checksum" || return 1

  actual_size=$(stat -c '%s' "$image_file") || return 1
  metadata_size=$(jq -r '.file_size' "$metadata_file") || return 1
  [[ "$actual_size" == "$metadata_size" ]] || return 1
  (( actual_size <= PF_IMAGE_MAX_BYTES )) || return 1

  pf_image_compute_checksum "$algorithm" "$image_file" || return 1
  actual_checksum="$PF_IMAGE_ACTUAL_CHECKSUM"
  [[ "$actual_checksum" == "$expected_checksum" ]] || return 1
  pf_image_validate_disk_image "$image_file" "$expected_format" || return 1

  PF_IMAGE_PATH="$image_file"
  PF_IMAGE_METADATA_JSON=$(<"$metadata_file")
  PF_IMAGE_CACHE_HIT=true
}

pf_image_acquire_locked() {
  local distribution="$1" descriptor_json="$2" release="$3" architecture="$4"
  local image_url checksum_url checksum_algorithm signature_url
  local allowed_hosts method trust_level disk_format filename keyring_id
  local stage_dir checksum_file signature_file image_temp metadata_temp
  local expected_checksum actual_checksum image_size cache_dir image_path metadata_path
  local timestamp publication_id

  image_url=$(jq -r '.url' <<< "$descriptor_json") || return 1
  checksum_url=$(jq -r '.checksum.url' <<< "$descriptor_json") || return 1
  checksum_algorithm=$(jq -r '.checksum.algorithm' <<< "$descriptor_json") || return 1
  filename=$(jq -r '.filename' <<< "$descriptor_json") || return 1
  disk_format=$(jq -r '.disk_format' <<< "$descriptor_json") || return 1
  allowed_hosts=$(jq -c '.allowed_hosts' <<< "$descriptor_json") || return 1
  method=$(jq -r '.verification.method' <<< "$descriptor_json") || return 1
  trust_level=$(jq -r '.verification.trust_level' <<< "$descriptor_json") || return 1
  signature_url=$(jq -r '.signature.url // empty' <<< "$descriptor_json") || return 1
  keyring_id=$(jq -r '.signature.keyring_id // empty' <<< "$descriptor_json") || return 1

  stage_dir=$(mktemp -d "${PF_IMAGE_CACHE_DIR}/.staging/${distribution}-${release}-${architecture}.XXXXXX") || {
    pf_image_error "Could not create a private image staging directory."
    return 1
  }
  checksum_file="$stage_dir/checksums"
  signature_file="$stage_dir/checksums.sig"
  image_temp="$stage_dir/image"
  metadata_temp="$stage_dir/metadata.json"

  if ! pf_image_download_url "$checksum_url" "$allowed_hosts" "$checksum_file" "$PF_IMAGE_CHECKSUM_MAX_BYTES"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  if [[ "$method" == "signed-checksum" ]]; then
    if ! pf_image_download_url "$signature_url" "$allowed_hosts" "$signature_file" "$PF_IMAGE_CHECKSUM_MAX_BYTES"; then
      rm -rf -- "$stage_dir"
      return 1
    fi
    if ! pf_image_verify_signature "$signature_file" "$checksum_file" "$keyring_id"; then
      rm -rf -- "$stage_dir"
      return 1
    fi
  fi

  if ! pf_image_read_expected_checksum "$checksum_file" "$filename" "$checksum_algorithm"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  expected_checksum="$PF_IMAGE_EXPECTED_CHECKSUM"
  cache_dir="${PF_IMAGE_CACHE_DIR}/${distribution}/${release}/${architecture}"
  image_path="$cache_dir/${expected_checksum}.${disk_format}"
  metadata_path="$image_path.json"

  mkdir -p -m 0750 -- "$cache_dir" || {
    rm -rf -- "$stage_dir"
    return 1
  }
  pf_image_check_secure_path "$cache_dir" directory || {
    pf_image_error "Image cache path is not trusted: $cache_dir"
    rm -rf -- "$stage_dir"
    return 1
  }

  if [[ -e "$image_path" || -L "$image_path" || -e "$metadata_path" || -L "$metadata_path" ]]; then
    if pf_image_cache_validate "$image_path" "$metadata_path" "$descriptor_json" "$distribution" "$expected_checksum" "$checksum_algorithm" "$disk_format"; then
      rm -rf -- "$stage_dir"
      pf_core_info "Verified image cache hit: $distribution $release ($architecture)"
      return 0
    fi
    pf_image_error "An incomplete or invalid cache entry already exists; it was left untouched: $image_path"
    rm -rf -- "$stage_dir"
    return 1
  fi

  if ! pf_image_download_url "$image_url" "$allowed_hosts" "$image_temp" "$PF_IMAGE_MAX_BYTES"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  image_size=$(stat -c '%s' "$image_temp") || {
    rm -rf -- "$stage_dir"
    return 1
  }
  (( image_size > 0 && image_size <= PF_IMAGE_MAX_BYTES )) || {
    pf_image_error "Image exceeds configured maximum size."
    rm -rf -- "$stage_dir"
    return 1
  }

  if ! pf_image_compute_checksum "$checksum_algorithm" "$image_temp"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  actual_checksum="$PF_IMAGE_ACTUAL_CHECKSUM"
  [[ "$actual_checksum" == "$expected_checksum" ]] || {
    pf_image_error "Image checksum mismatch. The image will not be cached or imported."
    rm -rf -- "$stage_dir"
    return 1
  }
  if ! pf_image_validate_disk_image "$image_temp" "$disk_format"; then
    rm -rf -- "$stage_dir"
    return 1
  fi

  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
    rm -rf -- "$stage_dir"
    return 1
  }
  publication_id="${release}:${filename}"
  jq -n \
    --arg distribution "$distribution" \
    --arg release "$release" \
    --arg architecture "$architecture" \
    --arg source_url "$image_url" \
    --arg filename "$filename" \
    --arg disk_format "$disk_format" \
    --arg algorithm "$checksum_algorithm" \
    --arg checksum "$expected_checksum" \
    --arg method "$method" \
    --arg trust "$trust_level" \
    --arg timestamp "$timestamp" \
    --arg publication_id "$publication_id" \
    --argjson file_size "$image_size" '
      {
        schema_version:1,
        distribution:$distribution,
        release:$release,
        architecture:$architecture,
        source_url:$source_url,
        filename:$filename,
        download_format:"file",
        archive_format:"none",
        disk_format:$disk_format,
        file_size:$file_size,
        checksum_algorithm:$algorithm,
        checksum_value:$checksum,
        verification_method:$method,
        verification_result:true,
        trust_level:$trust,
        verification_date:$timestamp,
        publication_identifier:$publication_id,
        cached_at:$timestamp
      }
    ' > "$metadata_temp" || {
      rm -rf -- "$stage_dir"
      return 1
    }
  jq -e . "$metadata_temp" >/dev/null || {
    pf_image_error "Could not generate valid cache metadata."
    rm -rf -- "$stage_dir"
    return 1
  }

  # Hard links publish without overwriting an entry created outside this lock.
  if ! ln -- "$image_temp" "$image_path"; then
    pf_image_error "Could not publish image without overwriting an existing cache entry."
    rm -rf -- "$stage_dir"
    return 1
  fi
  if ! ln -- "$metadata_temp" "$metadata_path"; then
    rm -f -- "$image_path"
    pf_image_error "Could not publish image metadata; the newly created image was removed."
    rm -rf -- "$stage_dir"
    return 1
  fi
  rm -rf -- "$stage_dir"

  if ! pf_image_cache_validate "$image_path" "$metadata_path" "$descriptor_json" "$distribution" "$expected_checksum" "$checksum_algorithm" "$disk_format"; then
    pf_image_error "Published image failed final cache verification."
    rm -f -- "$image_path" "$metadata_path"
    return 1
  fi

  PF_IMAGE_PATH="$image_path"
  PF_IMAGE_METADATA_JSON=$(<"$metadata_path")
  PF_IMAGE_CACHE_HIT=false
  pf_core_info "Verified image downloaded and cached: $distribution $release ($architecture)"
}

pf_image_acquire() {
  local distribution="$1" descriptor_json="$2"
  local release architecture lock_key lock_file lock_fd lock_timeout verification_method

  pf_image_init || return 1
  pf_core_is_safe_id "$distribution" || {
    pf_image_error "Invalid distribution identifier: $distribution"
    return 1
  }
  pf_image_validate_descriptor "$descriptor_json" || return 1
  release=$(jq -r '.release' <<< "$descriptor_json") || return 1
  architecture=$(jq -r '.architecture' <<< "$descriptor_json") || return 1
  pf_image_safe_token "$release" || {
    pf_image_error "Invalid release identifier for cache path."
    return 1
  }
  [[ "$architecture" == "x86_64" ]] || {
    pf_image_error "Unsupported image architecture: $architecture"
    return 1
  }

  PF_IMAGE_MAX_BYTES=$(jq -r '.image_max_bytes' <<< "$PF_CORE_CONFIG_JSON") || return 1
  PF_IMAGE_DOWNLOAD_TIMEOUT=$(jq -r '.image_download_timeout_seconds' <<< "$PF_CORE_CONFIG_JSON") || return 1
  lock_timeout=$(jq -r '.image_lock_timeout_seconds' <<< "$PF_CORE_CONFIG_JSON") || return 1
  [[ "$PF_IMAGE_MAX_BYTES" =~ ^[0-9]+$ && "$PF_IMAGE_DOWNLOAD_TIMEOUT" =~ ^[0-9]+$ && "$lock_timeout" =~ ^[0-9]+$ ]] || return 1

  verification_method=$(jq -r '.verification.method' <<< "$descriptor_json") || return 1
  if [[ "$verification_method" == "official-tls-checksum" &&
        "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" != "true" ]]; then
    pf_image_error "Official-TLS checksum verification is disabled by policy."
    return 1
  fi

  lock_key="${distribution}-${release}-${architecture}"
  lock_file="$PF_IMAGE_CACHE_DIR/.locks/$lock_key.lock"
  exec {lock_fd}> "$lock_file" || {
    pf_image_error "Could not open image cache lock."
    return 1
  }
  if ! flock -w "$lock_timeout" "$lock_fd"; then
    exec {lock_fd}>&-
    pf_image_error "Timed out waiting for image cache lock: $lock_key"
    return 1
  fi

  PF_IMAGE_CACHE_HIT=false
  PF_IMAGE_PATH=""
  PF_IMAGE_METADATA_JSON="{}"
  if pf_image_acquire_locked "$distribution" "$descriptor_json" "$release" "$architecture"; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return 1
}
