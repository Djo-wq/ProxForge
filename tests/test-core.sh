#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }
MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
PROXMOX_CALL_LOG="$TMP_ROOT/proxmox-calls.log"
export PROXMOX_CALL_LOG
for command_name in qm pct pvesh pvesm pveam pveversion qemu-img; do
  cat > "$MOCK_BIN/$command_name" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename -- "$0")" "$*" >> "$PROXMOX_CALL_LOG"
exit 99
MOCK
  chmod 755 "$MOCK_BIN/$command_name"
done
export PATH="$MOCK_BIN:$PATH"
export PF_CORE_TEST_MODE=1 PF_CORE_ROOT="$ROOT_DIR/src"
source "$ROOT_DIR/src/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"
pass "Core bootstrap and configuration initialization"
[[ "$PF_CORE_VERSION" == "1.0.0" ]] || fail "Core version was not loaded"
[[ "$(jq -r '.default_profile' <<< "$PF_CORE_CONFIG_JSON")" == "standard" ]] || fail "default profile mismatch"
[[ "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" == "false" ]] || fail "trust policy must default to false"
jq -e . "$ROOT_DIR/src/schemas/config.schema.json" >/dev/null || fail "Config schema is not valid JSON"
pass "default configuration and config schema loaded"
CONFIG_OVERRIDE="$TMP_ROOT/config.json"
cat > "$CONFIG_OVERRIDE" <<'JSON'
{"start_vm":false,"allow_official_tls_checksum":true,"log_level":"DEBUG"}
JSON
pf_core_config_load "$CONFIG_OVERRIDE" || fail "Valid configuration override rejected"
[[ "$(jq -r '.start_vm' <<< "$PF_CORE_CONFIG_JSON")" == "false" ]] || fail "explicit false was overwritten"
[[ "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" == "true" ]] || fail "explicit true was overwritten"
[[ "$PF_CORE_LOG_LEVEL" == "DEBUG" ]] || fail "log level override was not applied"
pass "configuration merge preserves explicit boolean false and true"
BAD_CONFIG="$TMP_ROOT/bad-config.json"
printf '{"unexpected_key":true}\n' > "$BAD_CONFIG"
if pf_core_config_load "$BAD_CONFIG" >/dev/null 2>&1; then fail "Unknown configuration key accepted"; fi
pass "unknown configuration keys rejected"
pf_core_profiles_list || fail "Profile list failed"
[[ "$(jq -r 'length' <<< "$PF_CORE_PROFILES_JSON")" == "4" ]] || fail "expected four profiles"
pf_core_profile_load standard || fail "Standard profile failed to load"
[[ "$(jq -r '.cpu_cores' <<< "$PF_CORE_PROFILE_JSON")" == "2" ]] || fail "standard CPU count mismatch"
if pf_core_profile_load '../standard' >/dev/null 2>&1; then fail "Path traversal profile identifier accepted"; fi
pass "profile listing, loading and path traversal rejection"
PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/tests/fixtures/modules"
pf_core_module_load valid || fail "Valid fixture module rejected"
[[ "$PF_CORE_LOADED_MODULE" == "valid" ]] || fail "loaded module id mismatch"
[[ "$(jq -r '.id' <<< "$PF_CORE_MODULE_METADATA_JSON")" == "valid" ]] || fail "module metadata projection mismatch"
pf_core_module_call pf_distro_list_releases 1 || fail "Release list result rejected"
[[ "$(jq -r 'length' <<< "$PF_MODULE_RESULT_JSON")" == "1" ]] || fail "release list result missing"
pf_core_module_call pf_distro_resolve_release 1 stable || fail "Resolved release result rejected"
pf_core_module_call pf_distro_get_image 1 1.0 x86_64 || fail "Image descriptor rejected"
bad_image=$(jq '.url="https://unapproved.example.invalid/fixture.qcow2"' <<< "$PF_MODULE_RESULT_JSON")
if pf_core_validate_module_result pf_distro_get_image "$bad_image"; then fail "Unapproved image host was accepted"; fi
bad_image=$(jq '.url="https://user@images.example.invalid/fixture.qcow2"' <<< "$PF_MODULE_RESULT_JSON")
if pf_core_validate_module_result pf_distro_get_image "$bad_image"; then fail "URL with credentials was accepted"; fi
pass "module result checks enforce host allow-list and reject embedded credentials"
assert_invalid_module() (
  local module_id="$1"
  PF_CORE_LOADED_MODULE=""
  PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/tests/fixtures/modules"
  if pf_core_module_load "$module_id" >/dev/null 2>&1; then fail "Invalid module accepted: $module_id"; fi
)
for module_id in invalid-api-version invalid-metadata invalid-missing-function invalid-stdout; do
  assert_invalid_module "$module_id" || fail "Invalid module check failed: $module_id"
  pass "invalid module rejected: $module_id"
done
PF_CORE_LOADED_MODULE=""
PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/tests/fixtures/modules"
if pf_core_module_load invalid-json >/dev/null 2>&1; then
  if pf_core_module_call pf_distro_list_releases 1 >/dev/null 2>&1; then fail "Malformed module result JSON accepted"; fi
else
  fail "Module with malformed result fixture did not load"
fi
pass "malformed structured module result rejected"
if [[ -s "$PROXMOX_CALL_LOG" ]]; then cat "$PROXMOX_CALL_LOG" >&2; fail "Core bootstrap called Proxmox/QEMU"; fi
pass "no Proxmox/QEMU command invoked during Phase 2 Core tests"
