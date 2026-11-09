#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }
command -v jq >/dev/null 2>&1 || fail "jq is required for schema tests"

check_schema() {
  local file="$1"
  jq -e '
    .["$schema"] == "https://json-schema.org/draft/2020-12/schema" and
    .type == "object" and
    .additionalProperties == false and
    (.required | type == "array" and length > 0)
  ' "$file" >/dev/null || fail "invalid schema document: $file"
  pass "schema JSON parses: $(basename -- "$file")"
}

assert_required_fields() {
  local file="$1" expected_json
  shift
  expected_json=$(printf '%s\n' "$@" | jq -R . | jq -cs .) || fail "could not build required-field test list"
  jq -e --argjson expected "$expected_json" '
    .required as $required |
    all($expected[]; . as $field | ($required | index($field)) != null)
  ' "$file" >/dev/null || fail "required fields missing in $(basename -- "$file")"
}

for schema in \
  "$ROOT_DIR/schemas/module.schema.json" \
  "$ROOT_DIR/schemas/profile.schema.json" \
  "$ROOT_DIR/schemas/image-metadata.schema.json" \
  "$ROOT_DIR/schemas/operation.schema.json" \
  "$ROOT_DIR/schemas/operation-event.schema.json" \
  "$ROOT_DIR/schemas/config.schema.json" \
  "$ROOT_DIR/schemas/trust-keyrings.schema.json" \
  "$ROOT_DIR/schemas/proxmox-inventory.schema.json"
do
  check_schema "$schema"
done

assert_required_fields "$ROOT_DIR/schemas/module.schema.json" api_version id name family version architectures
assert_required_fields "$ROOT_DIR/schemas/profile.schema.json" schema_version id name cpu_cores memory_mb disk_gb machine firmware scsi_controller network_model agent_enabled secure_boot
assert_required_fields "$ROOT_DIR/schemas/image-metadata.schema.json" schema_version distribution release architecture source_url filename disk_format file_size checksum_algorithm checksum_value verification_method verification_result trust_level verification_date publication_identifier cached_at
assert_required_fields "$ROOT_DIR/schemas/operation.schema.json" schema_version operation_id state vmid node distribution release profile image_digest storage rollback_mode created_resources rollback_status
assert_required_fields "$ROOT_DIR/schemas/operation-event.schema.json" schema_version operation_id sequence timestamp event state
assert_required_fields "$ROOT_DIR/schemas/config.schema.json" schema_version default_profile rollback_mode start_vm allow_official_tls_checksum image_cache_dir image_max_bytes image_download_timeout_seconds image_lock_timeout_seconds tmp_dir state_dir log_dir log_level
assert_required_fields "$ROOT_DIR/schemas/trust-keyrings.schema.json" schema_version keyrings
assert_required_fields "$ROOT_DIR/schemas/proxmox-inventory.schema.json" schema_version proxmox_version local_node nodes storages bridges virtual_machines_and_containers
pass "required fields are present in all schema contracts"

jq -e '.properties.api_version.const == "1" and .properties.architectures.items.enum == ["x86_64"]' "$ROOT_DIR/schemas/module.schema.json" >/dev/null || fail "module API contract mismatch"
jq -e '.properties.machine.const == "q35" and .properties.firmware.const == "ovmf" and .properties.secure_boot.type == "boolean"' "$ROOT_DIR/schemas/profile.schema.json" >/dev/null || fail "profile hardware contract mismatch"
jq -e '.properties.verification_result.const == true and (.properties.verification_method.enum | index("signed-checksum") != null) and (.properties.verification_method.enum | index("official-tls-checksum") != null)' "$ROOT_DIR/schemas/image-metadata.schema.json" >/dev/null || fail "image verification policy mismatch"
jq -e '(.properties.rollback_mode.enum == ["auto","keep"]) and (.properties.created_resources.items.properties.ownership_verified.type == "boolean")' "$ROOT_DIR/schemas/operation.schema.json" >/dev/null || fail "operation rollback/resource ownership mismatch"
jq -e '.properties.image_max_bytes.minimum == 1048576 and .properties.image_lock_timeout_seconds.maximum == 86400' "$ROOT_DIR/schemas/config.schema.json" >/dev/null || fail "image resource limits missing from config schema"
jq -e '.properties.keyrings.additionalProperties.properties.fingerprints.minItems == 1' "$ROOT_DIR/schemas/trust-keyrings.schema.json" >/dev/null || fail "trusted fingerprints are not required"
jq -e '.properties.schema_version.const == 1 and .properties.storages.items.properties.active.type == "boolean" and .properties.bridges.items.properties.iface.type == "string"' "$ROOT_DIR/schemas/proxmox-inventory.schema.json" >/dev/null || fail "Proxmox inventory schema mismatch"
pass "critical schema invariants are present"

for profile in minimal standard server heavy; do
  file="$ROOT_DIR/profiles/$profile.json"
  jq -e '
    .schema_version == 1 and
    (.id | type == "string" and length > 0) and
    (.cpu_cores | type == "number" and . >= 1) and
    (.memory_mb | type == "number" and . >= 128) and
    (.disk_gb | type == "number" and . >= 1) and
    .machine == "q35" and .firmware == "ovmf" and
    .scsi_controller == "virtio-scsi-pci" and .network_model == "virtio" and
    (.agent_enabled | type == "boolean") and
    (.secure_boot | type == "boolean")
  ' "$file" >/dev/null || fail "profile does not match Phase 1 contract: $profile"
  pass "profile accepted: $profile"
done

[[ "$(jq -r '.cpu_cores' "$ROOT_DIR/profiles/minimal.json")" == "1" ]] || fail "minimal CPU default mismatch"
[[ "$(jq -r '.memory_mb' "$ROOT_DIR/profiles/minimal.json")" == "1024" ]] || fail "minimal memory default mismatch"
[[ "$(jq -r '.disk_gb' "$ROOT_DIR/profiles/minimal.json")" == "8" ]] || fail "minimal disk default mismatch"
[[ "$(jq -r '.cpu_cores' "$ROOT_DIR/profiles/standard.json")" == "2" ]] || fail "standard CPU default mismatch"
[[ "$(jq -r '.memory_mb' "$ROOT_DIR/profiles/standard.json")" == "2048" ]] || fail "standard memory default mismatch"
[[ "$(jq -r '.disk_gb' "$ROOT_DIR/profiles/standard.json")" == "20" ]] || fail "standard disk default mismatch"
[[ "$(jq -r '.cpu_cores' "$ROOT_DIR/profiles/server.json")" == "4" ]] || fail "server CPU default mismatch"
[[ "$(jq -r '.memory_mb' "$ROOT_DIR/profiles/server.json")" == "4096" ]] || fail "server memory default mismatch"
[[ "$(jq -r '.disk_gb' "$ROOT_DIR/profiles/server.json")" == "40" ]] || fail "server disk default mismatch"
[[ "$(jq -r '.cpu_cores' "$ROOT_DIR/profiles/heavy.json")" == "8" ]] || fail "heavy CPU default mismatch"
[[ "$(jq -r '.memory_mb' "$ROOT_DIR/profiles/heavy.json")" == "8192" ]] || fail "heavy memory default mismatch"
[[ "$(jq -r '.disk_gb' "$ROOT_DIR/profiles/heavy.json")" == "100" ]] || fail "heavy disk default mismatch"
pass "all four initial profile resource presets match the reference specification"
