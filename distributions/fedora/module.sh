#!/usr/bin/env bash
# ProxForge Fedora Cloud distribution module. Trusted Bash code loaded by Core.

PF_MODULE_API_VERSION="1"
PF_MODULE_ID="fedora"
PF_MODULE_NAME="Fedora Cloud"
PF_MODULE_FAMILY="redhat"
PF_MODULE_VERSION="1.0.0"
PF_MODULE_ARCHES=("x86_64")

PF_FEDORA_IMAGE_BASE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases"
PF_FEDORA_IMAGE_HOST="download.fedoraproject.org"
PF_FEDORA_MIRROR_HOST="dl.fedoraproject.org"
PF_FEDORA_SIGNING_KEYRING="fedora-release"

pf_distro_init() {
  PF_MODULE_RESULT_JSON='{}'
  return 0
}

pf_distro_list_releases() {
  PF_MODULE_RESULT_JSON='[
    {
      "version":"45",
      "channel":"stable",
      "status":"supported",
      "release_date":"2026-11-03",
      "support_lifecycle":{
        "role":"current",
        "image_revision":"1.4",
        "image_kind":"Fedora Cloud Base Generic",
        "support_note":"Current stable Fedora release"
      }
    },
    {
      "version":"44",
      "channel":"stable",
      "status":"maintenance",
      "release_date":"2026-04-28",
      "support_lifecycle":{
        "role":"previous-supported",
        "image_revision":"1.7",
        "image_kind":"Fedora Cloud Base Generic",
        "support_note":"Previous supported stable Fedora release"
      }
    }
  ]'
  return 0
}

pf_distro_resolve_release() {
  local selector="$1"
  local version status release_date revision role note

  case "$selector" in
    latest|stable) version="45" ;;
    45|44) version="$selector" ;;
    *)
      printf '[ERROR] Fedora release is not in the pinned stable image catalog: %s\n' "$selector" >&2
      return 1
      ;;
  esac

  case "$version" in
    45)
      status="supported"
      release_date="2026-11-03"
      revision="1.4"
      role="current"
      note="Current stable Fedora release"
      ;;
    44)
      status="maintenance"
      release_date="2026-04-28"
      revision="1.7"
      role="previous-supported"
      note="Previous supported stable Fedora release"
      ;;
    *) return 1 ;;
  esac

  PF_MODULE_RESULT_JSON=$(jq -cn \
    --arg version "$version" \
    --arg status "$status" \
    --arg date "$release_date" \
    --arg revision "$revision" \
    --arg role "$role" \
    --arg note "$note" '{
      version:$version,
      channel:"stable",
      status:$status,
      release_date:$date,
      support_lifecycle:{
        role:$role,
        image_revision:$revision,
        image_kind:"Fedora Cloud Base Generic",
        support_note:$note
      }
    }') || return 1
}

pf_distro_get_image() {
  local release="$1" architecture="$2" revision filename checksum_filename base_url image_url checksum_url
  [[ "$architecture" == "x86_64" ]] || {
    printf '[ERROR] Fedora Cloud module supports x86_64 only.\n' >&2
    return 1
  }

  case "$release" in
    45) revision="1.4" ;;
    44) revision="1.7" ;;
    *)
      printf '[ERROR] No verified Fedora Cloud image is pinned for release %s.\n' "$release" >&2
      return 1
      ;;
  esac

  filename="Fedora-Cloud-Base-Generic-$release-$revision.x86_64.qcow2"
  checksum_filename="Fedora-Cloud-$release-$revision-x86_64-CHECKSUM"
  base_url="$PF_FEDORA_IMAGE_BASE_URL/$release/Cloud/x86_64/images"
  image_url="$base_url/$filename"
  checksum_url="$base_url/$checksum_filename"

  PF_MODULE_RESULT_JSON=$(jq -cn \
    --arg url "$image_url" \
    --arg filename "$filename" \
    --arg checksum_url "$checksum_url" \
    --arg checksum_filename "$checksum_filename" \
    --arg release "$release" \
    --arg keyring "$PF_FEDORA_SIGNING_KEYRING" \
    --arg image_host "$PF_FEDORA_IMAGE_HOST" \
    --arg mirror_host "$PF_FEDORA_MIRROR_HOST" '{
      url:$url,
      filename:$filename,
      allowed_hosts:[$image_host,$mirror_host],
      download_format:"file",
      archive_format:"none",
      disk_format:"qcow2",
      architecture:"x86_64",
      release:$release,
      checksum:{
        url:$checksum_url,
        algorithm:"sha256",
        filename:$checksum_filename
      },
      signature:{
        url:$checksum_url,
        format:"openpgp-clearsigned-checksum",
        keyring_id:$keyring
      },
      verification:{
        method:"signed-checksum",
        trust_level:"signed"
      },
      cloud_init:{
        status:"verified",
        datasource:"NoCloud"
      }
    }') || return 1
}

pf_distro_validate_image() {
  local image_path="$1" metadata_path="$2"
  local release filename expected_digest actual_digest actual_size expected_size

  [[ -f "$image_path" && ! -L "$image_path" && -s "$image_path" ]] || return 1
  [[ -f "$metadata_path" && ! -L "$metadata_path" && -r "$metadata_path" ]] || return 1

  jq -e '
    type == "object" and
    .schema_version == 1 and
    .distribution == "fedora" and
    .architecture == "x86_64" and
    .download_format == "file" and
    .archive_format == "none" and
    .disk_format == "qcow2" and
    .verification_method == "signed-checksum" and
    .verification_result == true and
    .trust_level == "signed" and
    .checksum_algorithm == "sha256" and
    (.release == "44" or .release == "45") and
    (.filename | type == "string" and
      test("^Fedora-Cloud-Base-Generic-(44-1[.]7|45-1[.]4)[.]x86_64[.]qcow2$")) and
    (.checksum_value | type == "string" and test("^[a-f0-9]{64}$")) and
    (.file_size | type == "number" and floor == . and . > 0) and
    (.source_url | type == "string" and startswith("https://download.fedoraproject.org/"))
  ' "$metadata_path" >/dev/null || return 1

  release=$(jq -r '.release' "$metadata_path") || return 1
  filename=$(jq -r '.filename' "$metadata_path") || return 1
  [[ "$filename" == Fedora-Cloud-Base-Generic-"$release"-* ]] || return 1

  expected_digest=$(jq -r '.checksum_value' "$metadata_path") || return 1
  expected_size=$(jq -r '.file_size' "$metadata_path") || return 1
  actual_size=$(stat -c '%s' "$image_path") || return 1
  [[ "$actual_size" == "$expected_size" ]] || return 1
  actual_digest=$(sha256sum -- "$image_path" | awk '{print $1}') || return 1
  [[ "$actual_digest" == "$expected_digest" ]]
}
