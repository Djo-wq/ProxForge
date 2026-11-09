#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$*"
}

command -v jq >/dev/null 2>&1 || fail "jq is required for the contract tests"

IMAGE_FIXTURE="$TMP_ROOT/image.qcow2"
METADATA_FIXTURE="$TMP_ROOT/image-metadata.json"
STDOUT_FILE="$TMP_ROOT/stdout"
STDERR_FILE="$TMP_ROOT/stderr"
printf 'fixture disk bytes\n' > "$IMAGE_FIXTURE"
printf '{"schema_version":1}\n' > "$METADATA_FIXTURE"

run_module_contract() (
  local module_file="$1"
  local expected_id
  expected_id=$(basename -- "$(dirname -- "$module_file")")

  unset PF_MODULE_API_VERSION PF_MODULE_ID PF_MODULE_NAME PF_MODULE_FAMILY PF_MODULE_VERSION PF_MODULE_ARCHES PF_MODULE_RESULT_JSON || true
  unset -f pf_distro_init pf_distro_list_releases pf_distro_resolve_release pf_distro_get_image pf_distro_validate_image || true

  # Fixtures are trusted local test files. Production module trust is documented separately.
  source "$module_file" || fail "source failed: $module_file"

  [[ "$PF_MODULE_API_VERSION" == "1" ]] || fail "$expected_id: incompatible or missing API version"
  [[ "$PF_MODULE_ID" == "$expected_id" ]] || fail "$expected_id: module ID does not match directory"
  [[ -n "$PF_MODULE_NAME" ]] || fail "$expected_id: module name is missing"
  [[ "$PF_MODULE_FAMILY" == "redhat" || "$PF_MODULE_FAMILY" == "debian" ]] || fail "$expected_id: invalid family"
  [[ "$PF_MODULE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || fail "$expected_id: invalid module version"
  declare -p PF_MODULE_ARCHES 2>/dev/null | grep -q '^declare -a PF_MODULE_ARCHES=' || fail "$expected_id: architectures must be a Bash indexed array"
  declare -p PF_MODULE_ARCHES 2>/dev/null | grep -q 'x86_64' || fail "$expected_id: x86_64 is not declared"

  local required_function
  for required_function in pf_distro_init pf_distro_list_releases pf_distro_resolve_release pf_distro_get_image pf_distro_validate_image; do
    declare -F "$required_function" >/dev/null || fail "$expected_id: missing function $required_function"
  done

  call_module_function() {
    local function_name="$1"
    shift
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"
    PF_MODULE_RESULT_JSON=""
    local status=0
    if "$function_name" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
      status=0
    else
      status=$?
    fi
    [[ ! -s "$STDOUT_FILE" ]] || fail "$expected_id: $function_name wrote to stdout"
    return "$status"
  }

  call_module_function pf_distro_init || fail "$expected_id: initialization failed"

  call_module_function pf_distro_list_releases || fail "$expected_id: list_releases failed"
  jq -e '
    type == "array" and length > 0 and
    all(.[]; type == "object" and
      (.version | type == "string" and length > 0) and
      (.channel == "stable" or .channel == "testing" or .channel == "beta" or .channel == "rawhide" or .channel == "archived") and
      (.status == "supported" or .status == "maintenance" or .status == "eol" or .status == "archived" or .status == "unknown"))
  ' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "$expected_id: invalid release list JSON contract"

  call_module_function pf_distro_resolve_release stable || fail "$expected_id: resolve_release failed"
  jq -e '
    type == "object" and
    (.version | type == "string" and length > 0) and
    (.channel == "stable" or .channel == "testing" or .channel == "beta" or .channel == "rawhide" or .channel == "archived") and
    (.status == "supported" or .status == "maintenance" or .status == "eol" or .status == "archived" or .status == "unknown")
  ' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "$expected_id: invalid resolved release JSON contract"

  call_module_function pf_distro_get_image 1.0 x86_64 || fail "$expected_id: get_image failed"
  jq -e '
    type == "object" and
    (.url | type == "string" and startswith("https://")) and
    (.filename | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
    (.allowed_hosts | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    .download_format == "file" and .archive_format == "none" and
    (.disk_format == "qcow2" or .disk_format == "raw") and
    .architecture == "x86_64" and
    (.release | type == "string" and length > 0) and
    (.checksum | type == "object" and (.url | type == "string" and startswith("https://")) and (.algorithm == "sha256" or .algorithm == "sha512") and (.filename | type == "string" and length > 0)) and
    (.signature == null or (.signature | type == "object" and (.url | type == "string" and startswith("https://")) and .format == "openpgp" and (.keyring_id | type == "string" and length > 0))) and
    (.verification | type == "object" and (.method == "signed-checksum" or .method == "official-tls-checksum") and (.trust_level == "signed" or .trust_level == "official_tls")) and
    (.cloud_init | type == "object" and (.status == "verified" or .status == "unverified" or .status == "unsupported"))
  ' <<< "$PF_MODULE_RESULT_JSON" >/dev/null || fail "$expected_id: invalid image descriptor JSON contract"

  call_module_function pf_distro_validate_image "$IMAGE_FIXTURE" "$METADATA_FIXTURE" || fail "$expected_id: validate_image rejected the fixture"
)

valid_module="$ROOT_DIR/tests/fixtures/modules/valid/module.sh"
run_module_contract "$valid_module"
pass "valid module is accepted and functions obey the current-shell result contract"

for invalid_module in \
  "$ROOT_DIR/tests/fixtures/modules/invalid-api-version/module.sh" \
  "$ROOT_DIR/tests/fixtures/modules/invalid-metadata/module.sh" \
  "$ROOT_DIR/tests/fixtures/modules/invalid-missing-function/module.sh" \
  "$ROOT_DIR/tests/fixtures/modules/invalid-stdout/module.sh" \
  "$ROOT_DIR/tests/fixtures/modules/invalid-json/module.sh"
do
  if run_module_contract "$invalid_module" >/dev/null 2>&1; then
    fail "invalid module was accepted: $invalid_module"
  fi
  pass "invalid module rejected: $(basename -- "$(dirname -- "$invalid_module")")"
done
