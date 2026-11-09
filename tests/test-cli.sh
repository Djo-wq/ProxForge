#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

CLI="$ROOT_DIR/proxforge.sh"
export PF_CORE_TEST_MODE=1
export PF_PVE_TEST_MODE=1
export PF_IMAGE_TEST_MODE=1
export PF_CORE_ROOT="$ROOT_DIR"
export PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/distributions"

# The image-cache command checks runtime tool availability but does not use
# qemu-img while enumerating cached metadata.
MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/qemu-img" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod 755 "$MOCK_BIN/qemu-img"
export PATH="$MOCK_BIN:$PATH"

bash "$CLI" --help > "$TMP_ROOT/help.txt" || fail "Global help failed"
grep -q 'module validate' "$TMP_ROOT/help.txt" || fail "Global help omits module validation"
grep -q 'image cache list' "$TMP_ROOT/help.txt" || fail "Global help omits image cache inventory"
bash "$CLI" --version > "$TMP_ROOT/version.txt" || fail "Global version failed"
grep -q 'Module API 1' "$TMP_ROOT/version.txt" || fail "Version output omits Module API"
bash "$CLI" version > "$TMP_ROOT/version-subcommand.txt" || fail "Version subcommand failed"
pass "Global help and version entry points"

MODULES=$(bash "$CLI" module list) || fail "Module inventory failed"
jq -e 'any(.[];.id=="fedora" and .loadable==true) and any(.[];.id=="debian" and .loadable==true)' \
  <<< "$MODULES" >/dev/null || fail "Module inventory did not list Fedora and Debian"

FEDORA=$(bash "$CLI" module show fedora) || fail "Fedora metadata inspection failed"
jq -e '.metadata.id=="fedora" and (.releases|length)==2' <<< "$FEDORA" >/dev/null ||
  fail "Fedora module show returned incomplete metadata"
DEBIAN=$(bash "$CLI" module releases debian) || fail "Debian release inspection failed"
jq -e 'length==1 and .[0].version=="13" and .[0].support_lifecycle.codename=="trixie"' \
  <<< "$DEBIAN" >/dev/null || fail "Debian release listing is incorrect"

FEDORA_VALID=$(bash "$CLI" module validate fedora) || fail "Fedora module validation failed"
jq -e '.valid==true and .metadata.id=="fedora" and all(.releases[];.image_descriptor_valid==true and .policy_allowed==true)' \
  <<< "$FEDORA_VALID" >/dev/null || fail "Fedora validation output is incomplete"

DEBIAN_VALID=$(bash "$CLI" module validate debian) || fail "Debian module contract validation failed"
jq -e '.valid==true and .metadata.id=="debian" and .releases[0].image_descriptor_valid==true and .releases[0].policy_allowed==false' \
  <<< "$DEBIAN_VALID" >/dev/null || fail "Debian opt-in policy state was not reported"
pass "Module list/show/releases/validate commands; Debian opt-in is reported rather than silently enabled"

DEBIAN_IMAGE=$(bash "$CLI" module image debian latest) || fail "Debian image descriptor inspection failed"
jq -e '.release.version=="13" and .image_descriptor.checksum.algorithm=="sha512" and .policy.acquisition_allowed==false' \
  <<< "$DEBIAN_IMAGE" >/dev/null || fail "Debian descriptor output did not include SHA-512/policy information"
FEDORA_IMAGE=$(bash "$CLI" module image fedora stable) || fail "Fedora image descriptor inspection failed"
jq -e '.release.version=="45" and .image_descriptor.signature.format=="openpgp-clearsigned-checksum" and .policy.acquisition_allowed==true' \
  <<< "$FEDORA_IMAGE" >/dev/null || fail "Fedora descriptor output is incorrect"
pass "Module image inspection resolves pinned releases without downloading image data"

CONFIG_FILE="$TMP_ROOT/config.json"
jq -n --arg cache "$TMP_ROOT/cache" '{image_cache_dir:$cache}' > "$CONFIG_FILE"
CONFIG_SHOW=$(bash "$CLI" --config "$CONFIG_FILE" config show) || fail "Global --config option failed"
jq -e --arg cache "$TMP_ROOT/cache" '.image_cache_dir==$cache and .allow_official_tls_checksum==false' \
  <<< "$CONFIG_SHOW" >/dev/null || fail "Configuration override merge did not preserve secure defaults"

CONFIG_PATH=$(bash "$CLI" --config "$CONFIG_FILE" config path) || fail "Configuration source inspection failed"
jq -e --arg source "$CONFIG_FILE" '.source_file==$source' <<< "$CONFIG_PATH" >/dev/null ||
  fail "Configuration source path was not reported"

CONFIG_VALID=$(bash "$CLI" config validate "$CONFIG_FILE") || fail "Explicit config validation failed"
jq -e '.valid==true and .config.allow_official_tls_checksum==false' <<< "$CONFIG_VALID" >/dev/null ||
  fail "Config validation output is incorrect"

BAD_CONFIG="$TMP_ROOT/bad-config.json"
printf '{"unknown_setting":true}\n' > "$BAD_CONFIG"
if bash "$CLI" config validate "$BAD_CONFIG" >/dev/null 2>&1; then
  fail "Unknown configuration key was accepted"
fi
pass "Global config selection, source path, defaults merge and strict validation"

CACHE_DIR="$TMP_ROOT/cache"
IMAGE_DIR="$CACHE_DIR/fedora/45/x86_64"
mkdir -p "$IMAGE_DIR"
IMAGE="$IMAGE_DIR/test-image.qcow2"
printf 'synthetic cached qcow2 bytes\n' > "$IMAGE"
IMAGE_SIZE=$(stat -c '%s' "$IMAGE")
IMAGE_DIGEST=$(sha256sum "$IMAGE" | awk '{print $1}')
jq -n --arg digest "$IMAGE_DIGEST" --argjson size "$IMAGE_SIZE" '{
  schema_version:1,distribution:"fedora",release:"45",architecture:"x86_64",
  source_url:"https://example.invalid/test-image.qcow2",filename:"test-image.qcow2",
  download_format:"file",archive_format:"none",disk_format:"qcow2",
  file_size:$size,checksum_algorithm:"sha256",checksum_value:$digest,
  verification_method:"signed-checksum",verification_result:true,trust_level:"signed",
  verification_date:"2026-11-09T00:00:00Z",publication_identifier:"45:test-image.qcow2",
  cached_at:"2026-11-09T00:00:00Z"
}' > "$IMAGE.json"
printf 'orphaned image bytes\n' > "$IMAGE_DIR/orphan.qcow2"

CACHE_LIST=$(bash "$CLI" --config "$CONFIG_FILE" image cache list) || fail "Image cache inventory failed"
if ! jq -e --arg path "$IMAGE" '
  length==2 and any(.[];.path==$path and .metadata_valid==true and
    .integrity_state=="metadata-consistent-not-rehashed" and .trust_level=="signed") and
  any(.[];(.path|endswith("orphan.qcow2")) and .metadata_valid==false)
' <<< "$CACHE_LIST" >/dev/null; then
  printf 'Cache inventory output: %s\n' "$CACHE_LIST" >&2
  fail "Cache inventory did not distinguish consistent and orphaned metadata"
fi
pass "Image cache inventory reports metadata status without claiming to re-hash cached bytes"

COMPLETION=$(bash "$CLI" completion bash) || fail "Bash completion generation failed"
grep -q 'complete -F _proxforge_complete proxforge.sh' <<< "$COMPLETION" ||
  fail "Bash completion registration is missing"

if bash "$CLI" not-a-command >/dev/null 2>&1; then
  fail "Unknown CLI command was accepted"
fi
if bash "$CLI" module image debian >/dev/null 2>&1; then
  fail "Missing module image selector argument was accepted"
fi
if bash "$CLI" deploy fedora stable standard local-lvm vmbr0 --unknown value >/dev/null 2>&1; then
  fail "Unknown deploy option was accepted"
fi
pass "Bash completion, unknown commands and invalid argument combinations"

# doctor emits a machine-readable report even when the current host is not
# ready for deployment. Its exit code reflects missing required host tools.
doctor_status=0
DOCTOR=$(bash "$CLI" doctor) || doctor_status=$?
jq -e '(.checks|type=="array") and (.modules|type=="array") and
  (.ready_for_deployment|type=="boolean") and (.failed_required_checks|type=="number")' \
  <<< "$DOCTOR" >/dev/null || fail "Doctor did not return a structured diagnostic report"
if jq -e '.ready_for_deployment==true' <<< "$DOCTOR" >/dev/null; then
  [[ "$doctor_status" == "0" ]] || fail "Doctor reported ready but returned a failure exit code"
else
  [[ "$doctor_status" != "0" ]] || fail "Doctor reported missing requirements but returned success"
fi
pass "Doctor emits machine-readable readiness and a matching exit status"

pass "CLI hermetic tests completed; no Proxmox command, image download or VM mutation used"
