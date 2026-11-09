#!/usr/bin/env bash
# ProxForge Debian Cloud distribution module. Trusted Bash code loaded by Core.

PF_MODULE_API_VERSION="1"
PF_MODULE_ID="debian"
PF_MODULE_NAME="Debian Cloud"
PF_MODULE_FAMILY="debian"
PF_MODULE_VERSION="1.0.0"
PF_MODULE_ARCHES=("x86_64")

PF_DEBIAN_IMAGE_BASE_URL="https://cdimage.debian.org/cdimage/cloud/trixie/latest"
PF_DEBIAN_ALLOWED_HOSTS=("cdimage.debian.org" "cloudfront.debian.net")

pf_distro_init() {
  PF_MODULE_RESULT_JSON='{}'
  return 0
}

pf_distro_list_releases() {
  PF_MODULE_RESULT_JSON='[
    {
      "version":"13",
      "channel":"stable",
      "status":"supported",
      "release_date":"2025-08-09",
      "support_lifecycle":{
        "codename":"trixie",
        "point_release":"13.7",
        "point_release_date":"2026-09-12",
        "full_support_until":"2028-08-09",
        "lts_until":"2030-06-30",
        "image_kind":"Debian Cloud Generic",
        "image_track":"latest",
        "support_note":"Current Debian stable release; current point release is 13.7"
      }
    }
  ]'
  return 0
}

pf_distro_resolve_release() {
  local selector="$1"
  case "$selector" in
    latest|stable|trixie|13|13.x|13.7)
      PF_MODULE_RESULT_JSON='{
        "version":"13",
        "channel":"stable",
        "status":"supported",
        "release_date":"2025-08-09",
        "support_lifecycle":{
          "codename":"trixie",
          "point_release":"13.7",
          "point_release_date":"2026-09-12",
          "full_support_until":"2028-08-09",
          "lts_until":"2030-06-30",
          "image_kind":"Debian Cloud Generic",
          "image_track":"latest",
          "support_note":"Current Debian stable release; current point release is 13.7"
        }
      }'
      ;;
    *)
      printf '[ERROR] Debian release is not in the pinned stable image catalog: %s\n' "$selector" >&2
      return 1
      ;;
  esac
}

pf_distro_get_image() {
  local release="$1" architecture="$2"
  local filename checksum_filename image_url checksum_url allowed_hosts

  [[ "$release" == "13" ]] || {
    printf '[ERROR] No Debian Cloud image is pinned for release %s.\n' "$release" >&2
    return 1
  }
  [[ "$architecture" == "x86_64" ]] || {
    printf '[ERROR] Debian Cloud module supports x86_64 only.\n' >&2
    return 1
  }

  filename="debian-13-generic-amd64.qcow2"
  checksum_filename="SHA512SUMS"
  image_url="$PF_DEBIAN_IMAGE_BASE_URL/$filename"
  checksum_url="$PF_DEBIAN_IMAGE_BASE_URL/$checksum_filename"
  allowed_hosts=$(printf '%s\n' "${PF_DEBIAN_ALLOWED_HOSTS[@]}" | jq -R . | jq -cs .) || return 1

  PF_MODULE_RESULT_JSON=$(jq -cn \
    --arg url "$image_url" \
    --arg filename "$filename" \
    --arg checksum_url "$checksum_url" \
    --arg checksum_filename "$checksum_filename" \
    --arg allowed_hosts "$allowed_hosts" \
    '{
      url:$url,
      filename:$filename,
      allowed_hosts:($allowed_hosts|fromjson),
      download_format:"file",
      archive_format:"none",
      disk_format:"qcow2",
      architecture:"x86_64",
      release:"13",
      checksum:{
        url:$checksum_url,
        algorithm:"sha512",
        filename:$checksum_filename
      },
      signature:null,
      verification:{
        method:"official-tls-checksum",
        trust_level:"official_tls"
      },
      cloud_init:{
        status:"verified",
        datasource:"NoCloud"
      }
    }') || return 1
}

pf_distro_validate_image() {
  local image_path="$1" metadata_path="$2"
  local filename expected_digest actual_digest actual_size expected_size

  [[ -f "$image_path" && ! -L "$image_path" && -s "$image_path" ]] || return 1
  [[ -f "$metadata_path" && ! -L "$metadata_path" && -r "$metadata_path" ]] || return 1

  jq -e '
    type == "object" and
    .schema_version == 1 and
    .distribution == "debian" and
    .release == "13" and
    .architecture == "x86_64" and
    .download_format == "file" and
    .archive_format == "none" and
    .disk_format == "qcow2" and
    .verification_method == "official-tls-checksum" and
    .verification_result == true and
    .trust_level == "official_tls" and
    .checksum_algorithm == "sha512" and
    .filename == "debian-13-generic-amd64.qcow2" and
    (.checksum_value | type == "string" and test("^[a-f0-9]{128}$")) and
    (.file_size | type == "number" and floor == . and . > 0) and
    (.source_url | type == "string" and
      startswith("https://cdimage.debian.org/cdimage/cloud/trixie/latest/"))
  ' "$metadata_path" >/dev/null || return 1

  filename=$(jq -r '.filename' "$metadata_path") || return 1
  [[ "$filename" == "debian-13-generic-amd64.qcow2" ]] || return 1
  expected_digest=$(jq -r '.checksum_value' "$metadata_path") || return 1
  expected_size=$(jq -r '.file_size' "$metadata_path") || return 1
  actual_size=$(stat -c '%s' "$image_path") || return 1
  [[ "$actual_size" == "$expected_size" ]] || return 1
  actual_digest=$(sha512sum -- "$image_path" | awk '{print $1}') || return 1
  [[ "$actual_digest" == "$expected_digest" ]]
}
