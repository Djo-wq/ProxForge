#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

export PF_CORE_ROOT="$ROOT_DIR/src"
export PF_CORE_TEST_MODE=1
export PF_PVE_TEST_MODE=1
export PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/src/distributions"

source "$ROOT_DIR/src/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"
pf_core_module_load debian || fail "Debian distribution module could not be loaded"

pf_core_module_call pf_distro_list_releases 1 || fail "Debian release list failed"
jq -e '
  length == 1 and
  .[0].version == "13" and .[0].channel == "stable" and .[0].status == "supported" and
  .[0].support_lifecycle.codename == "trixie" and
  .[0].support_lifecycle.point_release == "13.7" and
  .[0].support_lifecycle.full_support_until == "2028-08-09" and
  .[0].support_lifecycle.lts_until == "2030-06-30"
' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "Debian release catalog is inconsistent"
pass "Debian catalog exposes stable Trixie 13.7 and its documented support lifecycle"

for selector in latest stable trixie 13 13.x 13.7; do
  pf_core_module_call pf_distro_resolve_release 1 "$selector" ||
    fail "Debian selector did not resolve: $selector"
  jq -e '.version=="13" and .channel=="stable" and .status=="supported"' \
    <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "Debian selector returned an unexpected release: $selector"
done
if pf_core_module_call pf_distro_resolve_release 1 12 >/dev/null 2>&1; then
  fail "Unpinned Debian 12 release was accepted"
fi
if pf_core_module_call pf_distro_resolve_release 1 forky >/dev/null 2>&1; then
  fail "Debian testing release was accepted as stable"
fi
pass "latest, stable, codename and version selectors resolve; old/testing releases fail closed"

pf_core_module_call pf_distro_get_image 1 13 x86_64 || fail "Debian image descriptor failed"
DEBIAN_DESCRIPTOR="$PF_MODULE_RESULT_JSON"
jq -e '
  .release=="13" and
  .filename=="debian-13-generic-amd64.qcow2" and
  .checksum.url==("https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS") and
  .checksum.filename=="SHA512SUMS" and
  .checksum.algorithm=="sha512" and
  .disk_format=="qcow2" and .architecture=="x86_64" and
  .signature==null and
  .verification.method=="official-tls-checksum" and
  .verification.trust_level=="official_tls" and
  .cloud_init.status=="verified" and .cloud_init.datasource=="NoCloud" and
  (.allowed_hosts|index("cloud.debian.org")!=null) and
  (.allowed_hosts|index("cdimage.debian.org")!=null) and
  (.allowed_hosts|index("cloudfront.debian.net")!=null)
' <<< "$DEBIAN_DESCRIPTOR" >/dev/null || fail "Debian image descriptor does not match the official Cloud image contract"

if pf_core_module_call pf_distro_get_image 1 13 aarch64 >/dev/null 2>&1; then
  fail "Unsupported Debian architecture was accepted"
fi
if pf_core_module_call pf_distro_get_image 1 12 x86_64 >/dev/null 2>&1; then
  fail "Unpinned Debian image release was accepted"
fi
pass "Debian image descriptor pins official Trixie generic QCOW2, SHA512SUMS and NoCloud metadata"

# Debian's current Cloud images use HTTPS + SHA512SUMS, not a detached signature.
# ProxForge must reject that weaker trust mode unless the operator opts in.
PF_CORE_CONFIG_JSON=$(jq '.allow_official_tls_checksum=false' <<< "$PF_CORE_CONFIG_JSON")
if pf_image_validate_descriptor "$DEBIAN_DESCRIPTOR" >/dev/null 2>&1; then
  fail "Official-TLS Debian checksum was accepted while the policy opt-in was disabled"
fi
PF_CORE_CONFIG_JSON=$(jq '.allow_official_tls_checksum=true' <<< "$PF_CORE_CONFIG_JSON")
pf_image_validate_descriptor "$DEBIAN_DESCRIPTOR" ||
  fail "Debian descriptor was rejected after explicit official-TLS opt-in"
pass "Debian's official-TLS checksum mode remains blocked until explicitly enabled"

IMAGE="$TMP_ROOT/debian-13-generic-amd64.qcow2"
printf 'synthetic Debian QCOW2 fixture\n' > "$IMAGE"
IMAGE_SIZE=$(stat -c '%s' "$IMAGE")
IMAGE_DIGEST=$(sha512sum "$IMAGE" | awk '{print $1}')
IMAGE_TIME="2026-11-09T00:00:00Z"
FILENAME=$(jq -r '.filename' <<< "$DEBIAN_DESCRIPTOR")
SOURCE_URL=$(jq -r '.url' <<< "$DEBIAN_DESCRIPTOR")
jq -n \
  --arg filename "$FILENAME" \
  --arg source "$SOURCE_URL" \
  --arg digest "$IMAGE_DIGEST" \
  --arg timestamp "$IMAGE_TIME" \
  --argjson size "$IMAGE_SIZE" '{
    schema_version:1,distribution:"debian",release:"13",architecture:"x86_64",
    source_url:$source,filename:$filename,download_format:"file",archive_format:"none",
    disk_format:"qcow2",file_size:$size,checksum_algorithm:"sha512",checksum_value:$digest,
    verification_method:"official-tls-checksum",verification_result:true,trust_level:"official_tls",
    verification_date:$timestamp,publication_identifier:("13:" + $filename),cached_at:$timestamp
  }' > "$IMAGE.json"
pf_core_module_call pf_distro_validate_image 0 "$IMAGE" "$IMAGE.json" ||
  fail "Debian module rejected correct SHA-512/QCOW2 metadata"

printf 'tampered Debian image bytes\n' > "$IMAGE"
if pf_core_module_call pf_distro_validate_image 0 "$IMAGE" "$IMAGE.json" >/dev/null 2>&1; then
  fail "Debian module accepted image bytes that no longer match the SHA-512 metadata"
fi
pass "Debian image validation enforces the QCOW2 release contract, metadata and SHA-512 digest"

pass "Debian module hermetic tests completed; no public mirror, real image or Proxmox VM used"
