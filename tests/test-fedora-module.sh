#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

export PF_CORE_ROOT="$ROOT_DIR"
export PF_CORE_TEST_MODE=1
export PF_PVE_TEST_MODE=1
export PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/distributions"

source "$ROOT_DIR/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"
pf_core_module_load fedora || fail "Fedora distribution module could not be loaded"

pf_core_module_call pf_distro_list_releases 1 || fail "Fedora release list failed"
jq -e '
  length == 2 and
  .[0].version == "45" and .[0].channel == "stable" and .[0].status == "supported" and
  .[1].version == "44" and .[1].channel == "stable" and
  all(.[]; .support_lifecycle.image_kind == "Fedora Cloud Base Generic")
' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "Fedora release catalog is inconsistent"
pass "Fedora release catalog exposes pinned Fedora 45 and Fedora 44 Cloud images"

pf_core_module_call pf_distro_resolve_release 1 latest || fail "latest release resolution failed"
jq -e '.version=="45" and .channel=="stable" and .status=="supported"' \
  <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "latest did not resolve to Fedora 45"

pf_core_module_call pf_distro_resolve_release 1 stable || fail "stable release resolution failed"
jq -e '.version=="45"' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "stable did not resolve to Fedora 45"

pf_core_module_call pf_distro_resolve_release 1 44 || fail "Fedora 44 resolution failed"
jq -e '.version=="44" and .status=="maintenance"' <<< "$PF_MODULE_RESULT_JSON" >/dev/null ||
  fail "Fedora 44 lifecycle status is incorrect"

if pf_core_module_call pf_distro_resolve_release 1 43 >/dev/null 2>&1; then
  fail "Unpinned Fedora 43 release was accepted"
fi
pass "latest, stable and pinned historical release selectors resolve safely"

pf_core_module_call pf_distro_get_image 1 45 x86_64 || fail "Fedora 45 image descriptor failed"
FEDORA45_DESCRIPTOR="$PF_MODULE_RESULT_JSON"
jq -e '
  .release=="45" and
  .filename=="Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2" and
  .checksum.filename=="Fedora-Cloud-45-1.4-x86_64-CHECKSUM" and
  .disk_format=="qcow2" and .architecture=="x86_64" and
  .verification.method=="signed-checksum" and
  .verification.trust_level=="signed" and
  .signature.format=="openpgp-clearsigned-checksum" and
  .signature.url==.checksum.url and
  .cloud_init.status=="verified" and .cloud_init.datasource=="NoCloud"
' <<< "$FEDORA45_DESCRIPTOR" >/dev/null || fail "Fedora 45 image descriptor does not match its published Cloud image contract"
pf_image_validate_descriptor "$FEDORA45_DESCRIPTOR" || fail "Image Manager rejected Fedora 45 descriptor"

pf_core_module_call pf_distro_get_image 1 44 x86_64 || fail "Fedora 44 image descriptor failed"
jq -e '
  .release=="44" and
  .filename=="Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2" and
  .checksum.filename=="Fedora-Cloud-44-1.7-x86_64-CHECKSUM" and
  .verification.method=="signed-checksum"
' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "Fedora 44 descriptor does not match its published Cloud image contract"

if pf_core_module_call pf_distro_get_image 1 45 aarch64 >/dev/null 2>&1; then
  fail "Unsupported Fedora architecture was accepted"
fi
if pf_core_module_call pf_distro_get_image 1 43 x86_64 >/dev/null 2>&1; then
  fail "Unpinned Fedora image release was accepted"
fi
pass "Fedora 44/45 image descriptors use official QCOW2 and signed CHECKSUM URLs; other targets fail closed"

IMAGE="$TMP_ROOT/fedora-45.qcow2"
printf 'synthetic Fedora QCOW2 fixture\n' > "$IMAGE"
IMAGE_SIZE=$(stat -c '%s' "$IMAGE")
IMAGE_DIGEST=$(sha256sum "$IMAGE" | awk '{print $1}')
IMAGE_TIME="2026-11-09T00:00:00Z"
FILENAME=$(jq -r '.filename' <<< "$FEDORA45_DESCRIPTOR")
SOURCE_URL=$(jq -r '.url' <<< "$FEDORA45_DESCRIPTOR")
jq -n \
  --arg filename "$FILENAME" \
  --arg source "$SOURCE_URL" \
  --arg digest "$IMAGE_DIGEST" \
  --arg timestamp "$IMAGE_TIME" \
  --argjson size "$IMAGE_SIZE" '{
    schema_version:1,distribution:"fedora",release:"45",architecture:"x86_64",
    source_url:$source,filename:$filename,download_format:"file",archive_format:"none",
    disk_format:"qcow2",file_size:$size,checksum_algorithm:"sha256",checksum_value:$digest,
    verification_method:"signed-checksum",verification_result:true,trust_level:"signed",
    verification_date:$timestamp,publication_identifier:("45:" + $filename),cached_at:$timestamp
  }' > "$IMAGE.json"
pf_core_module_call pf_distro_validate_image 0 "$IMAGE" "$IMAGE.json" ||
  fail "Fedora module rejected correct signed QCOW2 metadata"

printf 'tampered image bytes\n' > "$IMAGE"
if pf_core_module_call pf_distro_validate_image 0 "$IMAGE" "$IMAGE.json" >/dev/null 2>&1; then
  fail "Fedora module accepted image bytes that no longer match the verified digest"
fi
pass "Fedora image validation enforces the signed SHA-256 metadata and the QCOW2 release contract"

pass "Fedora module hermetic tests completed; no public mirror, real image or Proxmox VM used"
