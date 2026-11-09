#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }
command -v jq >/dev/null 2>&1 || fail "jq is required for schema tests"

for schema in \
  "$ROOT_DIR/schemas/module.schema.json" \
  "$ROOT_DIR/schemas/profile.schema.json" \
  "$ROOT_DIR/schemas/image-metadata.schema.json" \
  "$ROOT_DIR/schemas/operation.schema.json" \
  "$ROOT_DIR/schemas/operation-event.schema.json"
do
  jq -e '.("$schema") == "https://json-schema.org/draft/2020-12/schema" and .type == "object" and (.additionalProperties == false)' "$schema" >/dev/null \
    || fail "invalid schema document: $schema"
  pass "schema JSON parses: $(basename -- "$schema")"
done

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
