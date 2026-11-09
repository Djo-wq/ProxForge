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
source "$ROOT_DIR/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"

STATE_ROOT="$TMP_ROOT/state"
mkdir -p "$STATE_ROOT"
PF_CORE_CONFIG_JSON=$(jq --arg state "$STATE_ROOT" '.state_dir=$state' "$ROOT_DIR/config/defaults.json")
PF_VM_STATE_ROOT="$STATE_ROOT"
OP_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OP_DIR="$STATE_ROOT/$OP_ID"
mkdir -m 0750 "$OP_DIR"

TIMESTAMP="2026-11-09T12:00:00Z"
DIGEST=$(printf 'phase6-test' | sha256sum | awk '{print $1}')
jq -n --arg id "$OP_ID" --arg timestamp "$TIMESTAMP" --arg digest "$DIGEST" '{
  schema_version:1,operation_id:$id,created_at:$timestamp,updated_at:$timestamp,
  state:"FAILED",vmid:300,node:"pve1",distribution:"fedora",release:"40",
  profile:"standard",image_digest:$digest,storage:"local-lvm",rollback_mode:"auto",
  rollback_status:"BLOCKED",
  created_resources:[
    {resource_type:"vm",vmid:300,node:"pve1",created_at:$timestamp,ownership_verified:true},
    {resource_type:"efi",volid:"local-lvm:vm-300-disk-efi",storage:"local-lvm",slot:"efidisk0",role:"efi",vmid:300,node:"pve1",created_at:$timestamp,ownership_verified:true},
    {resource_type:"volume",volid:"local-lvm:vm-300-disk-0",storage:"local-lvm",slot:"scsi0",role:"system",vmid:300,node:"pve1",created_at:$timestamp,ownership_verified:true},
    {resource_type:"cloudinit",volid:"local-lvm:cloudinit",storage:"local-lvm",slot:"ide2",role:"cloud-init",vmid:300,node:"pve1",created_at:$timestamp,ownership_verified:true}
  ]
}' > "$OP_DIR/operation.json"

jq -cn --arg id "$OP_ID" --arg timestamp "$TIMESTAMP" '{
  schema_version:1,operation_id:$id,sequence:1,timestamp:$timestamp,
  event:"INITIALIZED",state:"INITIALIZING",outcome:"SUCCESS"
}' > "$OP_DIR/events.jsonl"
: > "$OP_DIR/.lock"

pf_operations_validate_event_log "$OP_ID" "$OP_DIR/events.jsonl" || fail "Valid event journal was rejected"
[[ "$PF_VM_EVENT_SEQUENCE" == "1" ]] || fail "Event sequence count is incorrect"
pf_operations_load_operation "$OP_ID" || fail "Valid operation manifest did not load"
pf_operations_validate_owned_manifest || fail "Complete ownership manifest was rejected"
pass "Valid operation manifest and monotonically sequenced journal are accepted"

# A tampered owner record must prevent rollback before reaching the Proxmox adapter.
PF_VM_MANIFEST_JSON=$(jq '.created_resources[2].ownership_verified=false' <<< "$PF_VM_MANIFEST_JSON")
if pf_operations_validate_owned_manifest >/dev/null 2>&1; then
  fail "Unverified volume ownership was accepted"
fi
pass "Unverified resource ownership is rejected"

# Journal gaps, duplicate sequence numbers and cross-operation records must fail closed.
jq -cn --arg id "$OP_ID" --arg timestamp "$TIMESTAMP" '{
  schema_version:1,operation_id:$id,sequence:3,timestamp:$timestamp,
  event:"VALIDATED",state:"VALIDATING",outcome:"SUCCESS"
}' >> "$OP_DIR/events.jsonl"
if pf_operations_validate_event_log "$OP_ID" "$OP_DIR/events.jsonl" >/dev/null 2>&1; then
  fail "Event sequence gap was accepted"
fi
pass "Event sequence gaps are rejected"

jq -cn --arg id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" --arg timestamp "$TIMESTAMP" '{
  schema_version:1,operation_id:$id,sequence:2,timestamp:$timestamp,
  event:"VALIDATED",state:"VALIDATING",outcome:"SUCCESS"
}' > "$OP_DIR/events.jsonl"
if pf_operations_validate_event_log "$OP_ID" "$OP_DIR/events.jsonl" >/dev/null 2>&1; then
  fail "Cross-operation journal line was accepted"
fi
pass "Cross-operation journal records are rejected"

if pf_operations_valid_uuid "not-a-uuid"; then
  fail "Malformed operation identifier was accepted"
fi
pass "Operation UUID validation rejects malformed identifiers"

pass "Operations Manager hermetic tests completed; no Proxmox command or network used"
