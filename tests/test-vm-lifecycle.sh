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
export PF_CORE_DISTRIBUTIONS_DIR="$ROOT_DIR/tests/fixtures/modules"
source "$ROOT_DIR/src/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"

STATE_ROOT="$TMP_ROOT/state"
IMAGE_CACHE="$TMP_ROOT/image-cache"
mkdir -p "$IMAGE_CACHE"
IMAGE="$IMAGE_CACHE/fixture.qcow2"
printf 'synthetic fixture image used by VM lifecycle tests\n' > "$IMAGE"
IMAGE_SIZE=$(stat -c '%s' "$IMAGE")
IMAGE_TIME="2026-11-09T11:00:00Z"
IMAGE_DIGEST=$(sha256sum "$IMAGE" | awk '{print $1}')
jq -n --arg digest "$IMAGE_DIGEST" --arg timestamp "$IMAGE_TIME" --argjson size "$IMAGE_SIZE" '{
  schema_version:1,distribution:"valid",release:"1.0",architecture:"x86_64",
  source_url:"https://images.example.invalid/fixture-1.0.qcow2",filename:"fixture-1.0.qcow2",
  download_format:"file",archive_format:"none",disk_format:"qcow2",file_size:$size,
  checksum_algorithm:"sha256",checksum_value:$digest,verification_method:"official-tls-checksum",
  verification_result:true,trust_level:"official_tls",verification_date:$timestamp,
  publication_identifier:"1.0:fixture-1.0.qcow2",cached_at:$timestamp
}' > "$IMAGE.json"
export PF_IMAGE_PATH="$IMAGE"
export PF_IMAGE_CACHE_DIR="$IMAGE_CACHE"
export PF_IMAGE_CACHE_HIT=false
export PF_IMAGE_METADATA_JSON
PF_IMAGE_METADATA_JSON=$(<"$IMAGE.json")

PF_CORE_CONFIG_JSON=$(jq --arg state "$STATE_ROOT" --arg cache "$IMAGE_CACHE" '
  .state_dir=$state | .image_cache_dir=$cache | .start_vm=true |
  .allow_official_tls_checksum=true
' "$ROOT_DIR/src/config/defaults.json")

PF_FAKE_NEXT_VMID=300
PF_FAKE_START_COUNT=0
PF_FAKE_FAIL_CREATE=false
PF_FAKE_FAIL_IMPORT=false
PF_FAKE_FAIL_ATTACH=false
PF_FAKE_BLOCK_DESTROY=false
PF_FAKE_DESTROY_COUNT=0
PF_FAKE_VM_STATUS=stopped

pf_image_acquire() {
  PF_IMAGE_PATH="$IMAGE"
  PF_IMAGE_METADATA_JSON=$(<"$IMAGE.json")
  PF_IMAGE_CACHE_HIT=false
  return 0
}

pf_pve_init() {
  PF_PVE_NODE="pve1"
  PF_PVE_VERSION="9.2.13"
  PF_PVE_INITIALIZED=true
  return 0
}
pf_pve_refresh_inventory() {
  PF_PVE_NODES_JSON='[{"node":"pve1","status":"online"}]'
  PF_PVE_STORAGES_JSON='[{"storage":"local-lvm","enabled":true,"active":true,"content":"images"}]'
  PF_PVE_BRIDGES_JSON='[{"iface":"vmbr0","active":true}]'
  PF_PVE_RESOURCES_JSON='[]'
  return 0
}
pf_pve_validate_storage() { [[ "$1" == "local-lvm" ]]; }
pf_pve_validate_bridge() { [[ "$1" == "vmbr0" ]]; }
pf_pve_next_vmid() {
  PF_PVE_NEXT_VMID="$PF_FAKE_NEXT_VMID"
  PF_FAKE_NEXT_VMID=$((PF_FAKE_NEXT_VMID + 1))
}
pf_pve_vmid_is_available() { return 0; }

pf_pve_vm_create() {
  local vmid="$1" name="$2"
  PF_PVE_CREATED_VM_ID="$vmid"
  if [[ "$PF_FAKE_FAIL_CREATE" == "true" ]]; then return 1; fi
  PF_FAKE_VM_STATUS="stopped"
  PF_PVE_CREATED_VM_JSON=$(jq -cn --arg name "$name" --argjson vmid "$vmid" '{
    name:$name,tags:"proxforge",efidisk0:("local-lvm:vm-" + ($vmid|tostring) + "-disk-efi,efitype=4m")
  }')
  return 0
}
pf_pve_vm_import_disk() {
  local vmid="$1" storage="$3" volume
  if [[ "$PF_FAKE_FAIL_IMPORT" == "true" ]]; then return 1; fi
  volume="$storage:vm-$vmid-disk-0"
  PF_PVE_IMPORTED_VM_ID="$vmid"
  PF_PVE_IMPORTED_VOLUME="$volume"
  PF_PVE_IMPORTED_SLOT="unused0"
  PF_PVE_IMPORTED_RESOURCE_JSON=$(jq -cn --arg volume "$volume" --arg storage "$storage" --argjson vmid "$vmid" '
    {resource_type:"volume",volid:$volume,storage:$storage,slot:"unused0",vmid:$vmid,node:"pve1"}
  ')
  return 0
}
pf_pve_vm_attach_imported_disk() {
  [[ "$PF_FAKE_FAIL_ATTACH" != "true" && "$1" == "$PF_PVE_IMPORTED_VM_ID" &&
     "$2" == "scsi0" && "$3" == "$PF_PVE_IMPORTED_VOLUME" ]]
}
pf_pve_vm_configure_cloudinit() { [[ "$1" =~ ^[0-9]+$ && "$2" == "local-lvm" ]]; }
pf_pve_vm_start() {
  PF_FAKE_START_COUNT=$((PF_FAKE_START_COUNT + 1))
  PF_FAKE_VM_STATUS="running"
  return 0
}
pf_pve_vm_get_config() {
  local vmid="$1"
  PF_PVE_VM_CONFIG_JSON=$(jq -cn --argjson vmid "$vmid" '{
    name:("pf-valid-" + ($vmid|tostring)),tags:"proxforge",
    efidisk0:("local-lvm:vm-" + ($vmid|tostring) + "-disk-efi,efitype=4m"),
    scsi0:("local-lvm:vm-" + ($vmid|tostring) + "-disk-0"),
    ide2:"local-lvm:cloudinit"
  }')
}
pf_pve_vm_get_status() {
  PF_PVE_VM_STATUS_JSON=$(jq -cn --arg status "$PF_FAKE_VM_STATUS" '{status:$status}')
}
pf_pve_vm_destroy_managed() {
  local vmid="$1" node="$2" resources="$3"
  PF_PVE_DESTROY_MUTATION_STARTED=false
  PF_PVE_DESTROY_ERROR=""
  if [[ "$PF_FAKE_BLOCK_DESTROY" == "true" || "$PF_FAKE_VM_STATUS" != "stopped" ]]; then
    PF_PVE_DESTROY_ERROR="Mock rollback preflight refused a running or blocked VM."
    return 1
  fi
  PF_PVE_DESTROY_MUTATION_STARTED=true
  PF_PVE_DESTROYED_RESOURCES_JSON="$resources"
  PF_FAKE_DESTROY_COUNT=$((PF_FAKE_DESTROY_COUNT + 1))
  PF_FAKE_VM_STATUS="absent"
  return 0
}

reset_module() {
  PF_CORE_LOADED_MODULE=""
  unset -f pf_distro_init pf_distro_list_releases pf_distro_resolve_release pf_distro_get_image pf_distro_validate_image
}

# Full successful lifecycle: resolve -> image -> VM -> disk -> Cloud-Init -> start.
PF_VM_OPERATION_ID="11111111-1111-4111-8111-111111111111"
RESULT_FILE="$TMP_ROOT/success.json"
pf_vm_lifecycle_deploy valid latest standard local-lvm vmbr0 "" auto > "$RESULT_FILE" || fail "Successful lifecycle was rejected"
SUCCESS_MANIFEST="$STATE_ROOT/11111111-1111-4111-8111-111111111111/operation.json"
SUCCESS_EVENTS="$STATE_ROOT/11111111-1111-4111-8111-111111111111/events.jsonl"
[[ -f "$SUCCESS_MANIFEST" && -f "$SUCCESS_EVENTS" ]] || fail "Operation manifest or event journal was not persisted"
jq -e '.state=="COMPLETED" and .rollback_status=="NOT_REQUIRED" and .vmid==300 and (.created_resources|length)==4' \
  "$SUCCESS_MANIFEST" >/dev/null || fail "Completed manifest is incomplete"
jq -se '
  length >= 12 and
  .[0].event == "INITIALIZED" and
  any(.[]; .event == "VM_CREATE_INTENT" and .outcome == "INTENT") and
  any(.[]; .event == "DISK_IMPORT_INTENT" and .outcome == "INTENT") and
  any(.[]; .event == "VM_START_INTENT" and .outcome == "INTENT") and
  .[-1].event == "COMPLETED" and
  ([.[].sequence] == [range(1; length + 1)])
' "$SUCCESS_EVENTS" >/dev/null || fail "Operation event sequence or intent journal is invalid"
jq -e '.manifest.state=="COMPLETED" and .manifest.vmid==300' "$RESULT_FILE" >/dev/null || fail "Lifecycle result JSON is incorrect"
[[ "$PF_FAKE_START_COUNT" == "1" ]] || fail "VM start was not invoked exactly once"
pass "Full VM lifecycle completes and persists a schema-aligned manifest plus ordered intent/result events"

# Operation query commands consume the journal without mutating Proxmox.
pf_vm_lifecycle_operation_show "11111111-1111-4111-8111-111111111111" > "$TMP_ROOT/show.json" || fail "Operation show failed"
pf_vm_lifecycle_operation_list > "$TMP_ROOT/list.json" || fail "Operation list failed"
jq -e '.operation_id=="11111111-1111-4111-8111-111111111111"' "$TMP_ROOT/show.json" >/dev/null || fail "Operation show returned the wrong operation"
jq -e 'length==1 and .[0].state=="COMPLETED"' "$TMP_ROOT/list.json" >/dev/null || fail "Operation list returned the wrong entries"
pass "Operation show and list read the persisted journal"

# The read-only reconcile command reports the host state and explicitly refuses auto-resume.
pf_vm_lifecycle_reconcile "11111111-1111-4111-8111-111111111111" > "$TMP_ROOT/reconcile.json" || fail "Read-only reconcile failed"
jq -e '.proxforge_managed==true and .system_disk_present==true and .cloudinit_drive_present==true and .automatic_resume==false and .automatic_rollback==false' \
  "$TMP_ROOT/reconcile.json" >/dev/null || fail "Reconcile report did not preserve the no-auto-resume safety policy"
pass "Reconciliation reports Proxmox state without resuming or rolling back"

# A failure after disk import is automatically rolled back when every owned resource is verified.
reset_module
PF_FAKE_FAIL_ATTACH=true
PF_FAKE_BLOCK_DESTROY=false
PF_VM_OPERATION_ID="22222222-2222-4222-8222-222222222222"
if pf_vm_lifecycle_deploy valid latest standard local-lvm vmbr0 "" auto >/dev/null 2>&1; then
  fail "Injected disk-attach failure was reported as success"
fi
FAILED_MANIFEST="$STATE_ROOT/22222222-2222-4222-8222-222222222222/operation.json"
FAILED_EVENTS="$STATE_ROOT/22222222-2222-4222-8222-222222222222/events.jsonl"
jq -e '.state=="ROLLBACK_COMPLETED" and .rollback_status=="COMPLETED" and (.created_resources|length)==3' \
  "$FAILED_MANIFEST" >/dev/null || fail "Automatic rollback did not remove the verified operation-owned resources"
jq -se 'any(.[]; .event=="ROLLBACK_INTENT") and any(.[]; .event=="ROLLBACK_COMPLETED") and any(.[]; .event=="RESOURCE_REMOVED")' \
  "$FAILED_EVENTS" >/dev/null || fail "Rollback sequence was not persisted"
[[ "$PF_FAKE_DESTROY_COUNT" == "1" ]] || fail "Automatic rollback did not call the destroy adapter exactly once"
[[ "$PF_FAKE_START_COUNT" == "1" ]] || fail "Lifecycle continued to VM start after a configuration failure"
pass "Post-creation failure triggers guarded automatic rollback and records each removed resource"

# A failed rollback is blocked without deleting anything, then can be explicitly retried.
reset_module
PF_FAKE_FAIL_ATTACH=true
PF_FAKE_BLOCK_DESTROY=true
PF_VM_OPERATION_ID="44444444-4444-4444-8444-444444444444"
if pf_vm_lifecycle_deploy valid latest standard local-lvm vmbr0 "" auto >/dev/null 2>&1; then
  fail "Blocked rollback scenario was reported as success"
fi
BLOCKED_MANIFEST="$STATE_ROOT/44444444-4444-4444-8444-444444444444/operation.json"
jq -e '.state=="FAILED" and .rollback_status=="BLOCKED"' "$BLOCKED_MANIFEST" >/dev/null || fail "Unsafe rollback did not remain blocked"
[[ "$PF_FAKE_DESTROY_COUNT" == "1" ]] || fail "Blocked rollback performed a destructive action"
PF_FAKE_BLOCK_DESTROY=false
pf_operations_rollback_operation "44444444-4444-4444-8444-444444444444" > "$TMP_ROOT/manual-rollback.json" || fail "Explicit rollback retry failed"
jq -e '.state=="ROLLBACK_COMPLETED" and .rollback_status=="COMPLETED"' "$BLOCKED_MANIFEST" >/dev/null || fail "Manual rollback retry did not complete"
[[ "$PF_FAKE_DESTROY_COUNT" == "2" ]] || fail "Manual retry did not call the destroy adapter"
pass "Blocked rollback is non-destructive and explicit retry completes after the safety gate clears"

# Configuration may request an assembled but stopped VM.
reset_module
PF_FAKE_FAIL_ATTACH=false
PF_CORE_CONFIG_JSON=$(jq '.start_vm=false' <<< "$PF_CORE_CONFIG_JSON")
PF_VM_OPERATION_ID="33333333-3333-4333-8333-333333333333"
pf_vm_lifecycle_deploy valid latest standard local-lvm vmbr0 "" auto > "$TMP_ROOT/stopped.json" || fail "Stopped-VM lifecycle failed"
STOPPED_MANIFEST="$STATE_ROOT/33333333-3333-4333-8333-333333333333/operation.json"
jq -e '.state=="COMPLETED" and .vmid==303 and (.created_resources|length)==4' "$STOPPED_MANIFEST" >/dev/null || fail "Stopped VM operation did not complete"
[[ "$PF_FAKE_START_COUNT" == "1" ]] || fail "start_vm=false still started a VM"
pass "start_vm=false leaves the VM stopped while completing disk and Cloud-Init configuration"

# Controlled resume is allowed only before any VM mutation intent has been journaled.
PARENT_OPERATION_ID="55555555-5555-4555-8555-555555555555"
PARENT_DIR="$STATE_ROOT/$PARENT_OPERATION_ID"
mkdir -m 0750 "$PARENT_DIR"
: > "$PARENT_DIR/.lock"
jq -n '{
  distribution:"valid",requested_release:"latest",profile:"standard",
  storage:"local-lvm",bridge:"vmbr0",vm_name:"",requested_vmid:"auto"
}' > "$PARENT_DIR/request.json"
jq -cn --arg id "$PARENT_OPERATION_ID" --arg timestamp "$IMAGE_TIME" '{
  schema_version:1,operation_id:$id,sequence:1,timestamp:$timestamp,
  event:"INITIALIZED",state:"INITIALIZING",outcome:"SUCCESS"
}' > "$PARENT_DIR/events.jsonl"
jq -cn --arg id "$PARENT_OPERATION_ID" --arg timestamp "$IMAGE_TIME" '{
  schema_version:1,operation_id:$id,sequence:2,timestamp:$timestamp,
  event:"FAILED",state:"FAILED",outcome:"FAILURE"
}' >> "$PARENT_DIR/events.jsonl"

reset_module
PF_VM_OPERATION_ID=""
PF_VM_PARENT_OPERATION_ID=""
pf_operations_resume_operation "$PARENT_OPERATION_ID" > "$TMP_ROOT/resume.json" || fail "Pre-mutation operation resume failed"
RESUMED_OPERATION_ID=$(jq -r '.new_operation.operation_id' "$TMP_ROOT/resume.json")
RESUMED_MANIFEST="$STATE_ROOT/$RESUMED_OPERATION_ID/operation.json"
jq -e --arg parent "$PARENT_OPERATION_ID" '
  .state=="COMPLETED" and .parent_operation_id==$parent and
  .vmid==304 and (.created_resources|length)==4
' "$RESUMED_MANIFEST" >/dev/null || fail "Resumed deployment did not preserve its parent link or completed state"
jq -e --arg parent "$PARENT_OPERATION_ID" '.resumed_from==$parent' "$STATE_ROOT/$RESUMED_OPERATION_ID/request.json" >/dev/null || fail "Resumed request did not retain its parent operation ID"
[[ "$PF_FAKE_START_COUNT" == "1" ]] || fail "Resume ignored start_vm=false and started another VM"
pass "Interrupted pre-mutation operation resumes as a new linked operation with a fresh journal"

# Any VM-create intent is a hard boundary, even if no resource is yet recorded.
MUTATED_OPERATION_ID="66666666-6666-4666-8666-666666666666"
MUTATED_DIR="$STATE_ROOT/$MUTATED_OPERATION_ID"
mkdir -m 0750 "$MUTATED_DIR"
: > "$MUTATED_DIR/.lock"
cp "$PARENT_DIR/request.json" "$MUTATED_DIR/request.json"
jq -cn --arg id "$MUTATED_OPERATION_ID" --arg timestamp "$IMAGE_TIME" '{
  schema_version:1,operation_id:$id,sequence:1,timestamp:$timestamp,
  event:"VM_CREATE_INTENT",state:"VM_CREATING",outcome:"INTENT"
}' > "$MUTATED_DIR/events.jsonl"
NEXT_VMID_BEFORE_RESUME="$PF_FAKE_NEXT_VMID"
if pf_operations_resume_operation "$MUTATED_OPERATION_ID" >/dev/null 2>&1; then
  fail "Operation with a VM_CREATE_INTENT event was replayed"
fi
[[ "$PF_FAKE_NEXT_VMID" == "$NEXT_VMID_BEFORE_RESUME" ]] || fail "Rejected resume allocated a VMID"
pass "Any journaled VM-create intent blocks automatic replay before Proxmox is touched"

if pf_vm_lifecycle_operation_show "not-a-uuid" >/dev/null 2>&1; then fail "Invalid operation ID was accepted"; fi
pass "Invalid operation identifiers are rejected"

bash "$ROOT_DIR/proxforge.sh" help >/dev/null || fail "CLI help failed after adding lifecycle commands"
pass "CLI remains loadable without performing Proxmox actions"

pass "VM Lifecycle hermetic tests completed; no real Proxmox command or network used"
