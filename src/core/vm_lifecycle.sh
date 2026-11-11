#!/usr/bin/env bash
# ProxForge VM Lifecycle Manager. Sourced by Core; no host work at source time.

PF_VM_OPERATION_ID=""
PF_VM_PARENT_OPERATION_ID=""
PF_VM_OPERATION_DIR=""
PF_VM_MANIFEST_FILE=""
PF_VM_EVENTS_FILE=""
PF_VM_MANIFEST_JSON=""
PF_VM_EVENT_SEQUENCE=0
PF_VM_MUTATION_STARTED=false
PF_VM_CURRENT_STATE="INITIALIZING"
PF_VM_STATE_ROOT=""
PF_VM_LIFECYCLE_TEST_MODE=false
PF_VM_OPERATION_LOCKED=false
PF_VM_VMID_LOCKED=false

pf_vm_lifecycle_error() { pf_core_error "VM Lifecycle: $*"; }
pf_vm_lifecycle_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
pf_vm_lifecycle_valid_uuid() {
  [[ "$1" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-8][A-Fa-f0-9]{3}-[89AaBb][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]]
}

pf_vm_lifecycle_prepare_state_root() {
  local configured uid mode test_core=false
  configured=$(jq -r '.state_dir' <<< "$PF_CORE_CONFIG_JSON") || return 1
  [[ "$configured" == /* && "$configured" != "/" && "$configured" != *//* ]] || return 1
  [[ "$configured" != *"/../"* && "$configured" != *"/./"* && "$configured" != */.. && "$configured" != */. ]] || return 1
  [[ ! -L "$configured" ]] || { pf_vm_lifecycle_error "State directory must not be a symlink."; return 1; }
  mkdir -p -m 0750 -- "$configured" || return 1
  chmod 0750 -- "$configured" || return 1
  declare -p PF_CORE_TEST_MODE >/dev/null 2>&1 && [[ "$PF_CORE_TEST_MODE" == "1" ]] && test_core=true
  if [[ "$PF_VM_LIFECYCLE_TEST_MODE" != "true" && "$test_core" != "true" ]]; then
    [[ "$EUID" == "0" ]] || { pf_vm_lifecycle_error "Lifecycle operations require root."; return 1; }
    uid=$(stat -c '%u' "$configured") || return 1
    mode=$(stat -c '%a' "$configured") || return 1
    [[ "$uid" == "0" ]] && (( (8#$mode & 0022) == 0 )) || {
      pf_vm_lifecycle_error "State directory must be root-owned and not group/world writable."
      return 1
    }
  fi
  PF_VM_STATE_ROOT="$configured"
  pf_core_require_command flock || return 1
  pf_core_require_command date || return 1
  pf_core_require_command sha256sum || return 1
}

pf_vm_lifecycle_generate_id() {
  local candidate
  candidate="$PF_VM_OPERATION_ID"
  if [[ -z "$candidate" ]]; then
    [[ -r /proc/sys/kernel/random/uuid ]] || return 1
    candidate=$(</proc/sys/kernel/random/uuid) || return 1
  fi
  pf_vm_lifecycle_valid_uuid "$candidate" || { pf_vm_lifecycle_error "Operation ID must be a UUID."; return 1; }
  PF_VM_OPERATION_ID=$(printf '%s' "$candidate" | tr 'A-F' 'a-f')
}

pf_vm_lifecycle_unlock() {
  if [[ "$PF_VM_VMID_LOCKED" == "true" ]]; then
    flock -u 9 2>/dev/null || true
    exec 9>&-
    PF_VM_VMID_LOCKED=false
  fi
  if [[ "$PF_VM_OPERATION_LOCKED" == "true" ]]; then
    flock -u 8 2>/dev/null || true
    exec 8>&-
    PF_VM_OPERATION_LOCKED=false
  fi
}

pf_vm_lifecycle_begin() {
  local request="$1"
  PF_VM_OPERATION_DIR="$PF_VM_STATE_ROOT/$PF_VM_OPERATION_ID"
  PF_VM_MANIFEST_FILE="$PF_VM_OPERATION_DIR/operation.json"
  PF_VM_EVENTS_FILE="$PF_VM_OPERATION_DIR/events.jsonl"
  mkdir -m 0750 -- "$PF_VM_OPERATION_DIR" || { pf_vm_lifecycle_error "Operation directory exists or could not be created."; return 1; }
  exec 8> "$PF_VM_OPERATION_DIR/.lock" || return 1
  flock -n 8 || { exec 8>&-; return 1; }
  PF_VM_OPERATION_LOCKED=true
  (umask 027; : > "$PF_VM_EVENTS_FILE") || return 1
  printf '%s\n' "$request" > "$PF_VM_OPERATION_DIR/request.json" || return 1
  chmod 0640 "$PF_VM_EVENTS_FILE" "$PF_VM_OPERATION_DIR/request.json" || return 1
  PF_VM_EVENT_SEQUENCE=0
  PF_VM_MANIFEST_JSON=""
  PF_VM_MUTATION_STARTED=false
  PF_VM_CURRENT_STATE="INITIALIZING"
}

pf_vm_lifecycle_event() {
  local event="$1" state="$2" outcome="" action="" details='{}' resource='null' timestamp json
  (( $# >= 3 )) && outcome="$3"
  (( $# >= 4 )) && action="$4"
  (( $# >= 5 )) && details="$5"
  (( $# >= 6 )) && resource="$6"
  [[ -n "$outcome" ]] || outcome="OBSERVED"
  case "$event" in
    INITIALIZED|VALIDATED|MODULE_LOADED|IMAGE_RESOLVED|IMAGE_DOWNLOAD_INTENT|IMAGE_DOWNLOADED|IMAGE_VERIFIED|VM_CREATE_INTENT|VM_CREATED|DISK_IMPORT_INTENT|DISK_IMPORTED|VM_CONFIGURED|CLOUD_INIT_CONFIGURED|VM_START_INTENT|VM_STARTED|COMPLETED|FAILED|RECONCILIATION_REQUIRED|ROLLBACK_INTENT|RESOURCE_REMOVED|ROLLBACK_COMPLETED|ROLLBACK_INCOMPLETE) ;;
    *) pf_vm_lifecycle_error "Unsupported event: $event"; return 1 ;;
  esac
  case "$state" in
    INITIALIZING|VALIDATING|MODULE_LOADING|IMAGE_RESOLVING|IMAGE_DOWNLOADING|IMAGE_VERIFYING|VM_CREATING|DISK_IMPORTING|VM_CONFIGURING|CLOUD_INIT_CONFIGURING|VM_STARTING|COMPLETED|FAILED|ROLLBACK_REQUIRED|ROLLING_BACK|ROLLBACK_COMPLETED|ROLLBACK_INCOMPLETE) ;;
    *) pf_vm_lifecycle_error "Unsupported state: $state"; return 1 ;;
  esac
  [[ "$outcome" == "INTENT" || "$outcome" == "SUCCESS" || "$outcome" == "FAILURE" || "$outcome" == "OBSERVED" ]] || return 1
  jq -e 'type == "object"' <<< "$details" >/dev/null || return 1
  jq -e 'type == "object" or type == "null"' <<< "$resource" >/dev/null || return 1
  timestamp=$(pf_vm_lifecycle_now) || return 1
  ((PF_VM_EVENT_SEQUENCE+=1))
  json=$(jq -cn --arg id "$PF_VM_OPERATION_ID" --arg timestamp "$timestamp" \
    --arg event "$event" --arg state "$state" --arg action "$action" --arg outcome "$outcome" \
    --argjson sequence "$PF_VM_EVENT_SEQUENCE" --argjson details "$details" --argjson resource "$resource" '
      {schema_version:1,operation_id:$id,sequence:$sequence,timestamp:$timestamp,event:$event,state:$state} +
      (if $action == "" then {} else {action:$action} end) + {outcome:$outcome} +
      (if $details == {} then {} else {details:$details} end) +
      (if $resource == null then {} else {resource:$resource} end)
    ') || return 1
  printf '%s\n' "$json" >> "$PF_VM_EVENTS_FILE" || return 1
  PF_VM_CURRENT_STATE="$state"
}

pf_vm_lifecycle_write_manifest() {
  local json="$1" temp
  jq -e 'type == "object" and .schema_version == 1 and
    (.operation_id | type == "string") and
    (.image_digest | type == "string" and test("^[a-f0-9]{64}$")) and
    (.created_resources | type == "array")' <<< "$json" >/dev/null || {
    pf_vm_lifecycle_error "Operation manifest does not match the Phase 1 contract."
    return 1
  }
  temp=$(mktemp "$PF_VM_OPERATION_DIR/.operation.XXXXXX") || return 1
  printf '%s\n' "$json" > "$temp" || { rm -f -- "$temp"; return 1; }
  chmod 0640 "$temp" || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$PF_VM_MANIFEST_FILE" || { rm -f -- "$temp"; return 1; }
  PF_VM_MANIFEST_JSON="$json"
}

pf_vm_lifecycle_set_state() {
  local state="$1" rollback="" timestamp json
  (( $# >= 2 )) && rollback="$2"
  timestamp=$(pf_vm_lifecycle_now) || return 1
  json=$(jq -c --arg state "$state" --arg timestamp "$timestamp" --arg rollback "$rollback" '
    .state=$state | .updated_at=$timestamp |
    (if $rollback == "" then . else .rollback_status=$rollback end)
  ' <<< "$PF_VM_MANIFEST_JSON") || return 1
  pf_vm_lifecycle_write_manifest "$json" || return 1
  PF_VM_CURRENT_STATE="$state"
}

pf_vm_lifecycle_add_resource() {
  local resource="$1" timestamp json
  if ! jq -e 'type == "object" and (.resource_type|type=="string") and (.created_at|type=="string") and (.ownership_verified|type=="boolean")' <<< "$resource" >/dev/null; then
    pf_vm_lifecycle_error "Resource record is invalid: $(jq -c . <<< "$resource" 2>/dev/null || printf 'unparseable-json')"
    return 1
  fi
  timestamp=$(pf_vm_lifecycle_now) || return 1
  json=$(jq -c --argjson resource "$resource" --arg timestamp "$timestamp" '
    .created_resources += [$resource] | .updated_at=$timestamp
  ' <<< "$PF_VM_MANIFEST_JSON") || {
    pf_vm_lifecycle_error "Could not append resource record to operation manifest."
    return 1
  }
  pf_vm_lifecycle_write_manifest "$json" || {
    pf_vm_lifecycle_error "Could not atomically persist updated operation manifest."
    return 1
  }
}

pf_vm_lifecycle_vm_resource() {
  local vmid="$1" node="$2" ownership="$3" timestamp
  timestamp=$(pf_vm_lifecycle_now) || return 1
  jq -cn --arg node "$node" --arg timestamp "$timestamp" --argjson vmid "$vmid" --argjson ownership "$ownership" '
    {resource_type:"vm",vmid:$vmid,node:$node,created_at:$timestamp,ownership_verified:$ownership}
  '
}

pf_vm_lifecycle_abort() {
  local message="$1"
  if declare -F pf_operations_handle_failure >/dev/null 2>&1; then
    pf_operations_handle_failure "$message"
  else
    pf_vm_lifecycle_error "$message"
    pf_vm_lifecycle_unlock
  fi
  return 1
}

pf_vm_lifecycle_make_manifest() {
  local vmid="$1" node="$2" dist="$3" release="$4" profile="$5" digest="$6" storage="$7" rollback="$8"
  local timestamp json parent
  timestamp=$(pf_vm_lifecycle_now) || return 1
  parent="$PF_VM_PARENT_OPERATION_ID"
  json=$(jq -cn --arg id "$PF_VM_OPERATION_ID" --arg timestamp "$timestamp" \
    --arg node "$node" --arg dist "$dist" --arg release "$release" --arg profile "$profile" \
    --arg digest "$digest" --arg storage "$storage" --arg rollback "$rollback" --arg parent "$parent" --argjson vmid "$vmid" '
      {schema_version:1,operation_id:$id,created_at:$timestamp,updated_at:$timestamp,
       state:"VM_CREATING",vmid:$vmid,node:$node,distribution:$dist,release:$release,
       profile:$profile,image_digest:$digest,storage:$storage,rollback_mode:$rollback,
       created_resources:[],rollback_status:"NOT_REQUIRED"} +
       (if $parent == "" then {} else {parent_operation_id:$parent} end)
    ') || return 1
  pf_vm_lifecycle_write_manifest "$json"
}

pf_vm_lifecycle_deploy() {
  local dist="$1" requested_release="$2" profile_id="$3" storage="$4" bridge="$5"
  local requested_name="" requested_vmid="auto"
  local details resolved_json descriptor_json release channel lifecycle_status
  local image_path digest trust profile_json vmid vm_name rollback start_vm
  local vm_resource volume_resource efi_resource cloudinit_resource efi_volid efi_storage

  (( $# >= 6 )) && requested_name="$6"
  (( $# >= 7 )) && requested_vmid="$7"
  PF_VM_MANIFEST_JSON=""
  PF_VM_EVENT_SEQUENCE=0
  PF_VM_MUTATION_STARTED=false
  PF_PVE_CREATED_VM_ID=""
  PF_PVE_CREATED_VM_JSON="{}"
  PF_PVE_IMPORTED_RESOURCE_JSON="{}"

  pf_core_is_safe_id "$dist" || { pf_vm_lifecycle_error "Invalid distribution ID."; return 2; }
  pf_core_is_safe_id "$profile_id" || { pf_vm_lifecycle_error "Invalid profile ID."; return 2; }
  pf_pve_valid_storage_id "$storage" || { pf_vm_lifecycle_error "Invalid storage ID."; return 2; }
  pf_pve_valid_bridge "$bridge" || { pf_vm_lifecycle_error "Invalid bridge ID."; return 2; }
  [[ "$requested_release" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || { pf_vm_lifecycle_error "Invalid release selector."; return 2; }
  [[ "$requested_vmid" == "auto" ]] || pf_pve_valid_vmid "$requested_vmid" || { pf_vm_lifecycle_error "VMID must be auto or an integer from 100 to 999999999."; return 2; }
  if [[ -n "$requested_name" ]]; then pf_pve_valid_vm_name "$requested_name" || { pf_vm_lifecycle_error "Invalid VM name."; return 2; }; fi

  pf_vm_lifecycle_prepare_state_root || return 1
  pf_vm_lifecycle_generate_id || return 1
  details=$(jq -cn --arg dist "$dist" --arg release "$requested_release" --arg profile "$profile_id" \
    --arg storage "$storage" --arg bridge "$bridge" --arg name "$requested_name" --arg vmid "$requested_vmid" --arg parent "$PF_VM_PARENT_OPERATION_ID" '
      {distribution:$dist,requested_release:$release,profile:$profile,storage:$storage,bridge:$bridge,vm_name:$name,requested_vmid:$vmid} +
      (if $parent == "" then {} else {resumed_from:$parent} end)
    ') || return 1
  pf_vm_lifecycle_begin "$details" || return 1
  pf_vm_lifecycle_event INITIALIZED INITIALIZING SUCCESS "Operation initialized" "$details" || { pf_vm_lifecycle_unlock; return 1; }

  pf_pve_init || { pf_vm_lifecycle_abort "Proxmox preflight failed."; return 1; }
  pf_core_profile_load "$profile_id" || { pf_vm_lifecycle_abort "Hardware profile validation failed."; return 1; }
  profile_json="$PF_CORE_PROFILE_JSON"
  pf_pve_refresh_inventory || { pf_vm_lifecycle_abort "Proxmox inventory refresh failed."; return 1; }
  pf_pve_validate_storage "$storage" || { pf_vm_lifecycle_abort "Storage is not available for VM images."; return 1; }
  pf_pve_validate_bridge "$bridge" || { pf_vm_lifecycle_abort "Network bridge is not available."; return 1; }
  pf_vm_lifecycle_event VALIDATED VALIDATING SUCCESS "Inputs and Proxmox targets validated" || { pf_vm_lifecycle_abort "Could not journal validation."; return 1; }

  pf_core_module_load "$dist" || { pf_vm_lifecycle_abort "Distribution module could not be loaded."; return 1; }
  pf_vm_lifecycle_event MODULE_LOADED MODULE_LOADING SUCCESS "Distribution module loaded" || { pf_vm_lifecycle_abort "Could not journal module load."; return 1; }
  pf_core_module_call pf_distro_resolve_release 1 "$requested_release" || { pf_vm_lifecycle_abort "Release resolution failed."; return 1; }
  resolved_json="$PF_MODULE_RESULT_JSON"
  release=$(jq -r '.version' <<< "$resolved_json") || { pf_vm_lifecycle_abort "Module returned no canonical release."; return 1; }
  channel=$(jq -r '.channel' <<< "$resolved_json") || { pf_vm_lifecycle_abort "Module returned no release channel."; return 1; }
  lifecycle_status=$(jq -r '.status' <<< "$resolved_json") || { pf_vm_lifecycle_abort "Module returned no lifecycle status."; return 1; }
  [[ "$release" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || { pf_vm_lifecycle_abort "Canonical release is unsafe."; return 1; }
  [[ "$channel" == "stable" && ( "$lifecycle_status" == "supported" || "$lifecycle_status" == "maintenance" ) ]] || {
    pf_vm_lifecycle_abort "Only supported or maintenance stable releases can be deployed."
    return 1
  }

  pf_core_module_call pf_distro_get_image 1 "$release" x86_64 || { pf_vm_lifecycle_abort "Image descriptor resolution failed."; return 1; }
  descriptor_json="$PF_MODULE_RESULT_JSON"
  [[ "$(jq -r '.release' <<< "$descriptor_json")" == "$release" ]] || { pf_vm_lifecycle_abort "Image descriptor release mismatch."; return 1; }
  [[ "$(jq -r '.cloud_init.status' <<< "$descriptor_json")" == "verified" ]] || {
    pf_vm_lifecycle_abort "The image module has not verified Cloud-Init support."
    return 1
  }
  details=$(jq -cn --arg release "$release" --arg channel "$channel" --arg status "$lifecycle_status" \
    --argjson descriptor "$descriptor_json" '
      {release:$release,channel:$channel,status:$status,image_url:$descriptor.url,
       disk_format:$descriptor.disk_format,architecture:$descriptor.architecture}
    ') || details='{}'
  pf_vm_lifecycle_event IMAGE_RESOLVED IMAGE_RESOLVING SUCCESS "Image descriptor resolved" "$details" || {
    pf_vm_lifecycle_abort "Could not journal image resolution."
    return 1
  }

  pf_vm_lifecycle_event IMAGE_DOWNLOAD_INTENT IMAGE_DOWNLOADING INTENT "Acquire verified image" || {
    pf_vm_lifecycle_abort "Could not journal image download intent."
    return 1
  }
  pf_image_acquire "$dist" "$descriptor_json" || { pf_vm_lifecycle_abort "Verified image acquisition failed."; return 1; }
  image_path="$PF_IMAGE_PATH"
  [[ -f "$image_path" && ! -L "$image_path" ]] || { pf_vm_lifecycle_abort "Image Manager returned no regular image file."; return 1; }
  pf_core_module_call pf_distro_validate_image 0 "$image_path" "$image_path.json" || {
    pf_vm_lifecycle_abort "Distribution-specific image validation failed."
    return 1
  }
  digest=$(sha256sum -- "$image_path" | awk '{print $1}') || { pf_vm_lifecycle_abort "Could not calculate SHA-256 operation digest."; return 1; }
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || { pf_vm_lifecycle_abort "Operation digest is malformed."; return 1; }
  trust=$(jq -r '.trust_level' <<< "$PF_IMAGE_METADATA_JSON") || { pf_vm_lifecycle_abort "Verified image metadata missing."; return 1; }
  details=$(jq -cn --arg path "$image_path" --arg digest "$digest" --arg trust "$trust" \
    --argjson cache_hit "$PF_IMAGE_CACHE_HIT" '{image_path:$path,image_digest:$digest,trust_level:$trust,cache_hit:$cache_hit}') || details='{}'
  pf_vm_lifecycle_event IMAGE_DOWNLOADED IMAGE_VERIFYING SUCCESS "Image acquired" "$details" || { pf_vm_lifecycle_abort "Could not journal image acquisition."; return 1; }
  pf_vm_lifecycle_event IMAGE_VERIFIED IMAGE_VERIFYING SUCCESS "Image digest and module validation passed" "$details" || { pf_vm_lifecycle_abort "Could not journal image verification."; return 1; }

  exec 9> "$PF_VM_STATE_ROOT/.vmid-allocation.lock" || { pf_vm_lifecycle_abort "Could not open VMID allocation lock."; return 1; }
  flock -w 120 9 || { exec 9>&-; pf_vm_lifecycle_abort "Timed out waiting for VMID allocation lock."; return 1; }
  PF_VM_VMID_LOCKED=true
  if [[ "$requested_vmid" == "auto" ]]; then
    pf_pve_next_vmid || { pf_vm_lifecycle_abort "Could not allocate a VMID."; return 1; }
    vmid="$PF_PVE_NEXT_VMID"
  else
    vmid="$requested_vmid"
    PF_PVE_RESOURCES_JSON=""
    pf_pve_refresh_inventory || { pf_vm_lifecycle_abort "Could not refresh VMID inventory."; return 1; }
    pf_pve_vmid_is_available "$vmid" || { pf_vm_lifecycle_abort "Requested VMID is already used."; return 1; }
  fi
  pf_pve_valid_vmid "$vmid" || { pf_vm_lifecycle_abort "Proxmox returned an invalid VMID."; return 1; }
  if [[ -n "$requested_name" ]]; then
    vm_name="$requested_name"
  else
    vm_name="pf-$dist-$vmid"
  fi
  pf_pve_valid_vm_name "$vm_name" || { pf_vm_lifecycle_abort "Generated VM name is invalid."; return 1; }

  rollback=$(jq -r '.rollback_mode' <<< "$PF_CORE_CONFIG_JSON") || { pf_vm_lifecycle_abort "Could not read rollback policy."; return 1; }
  pf_vm_lifecycle_make_manifest "$vmid" "$PF_PVE_NODE" "$dist" "$release" "$profile_id" "$digest" "$storage" "$rollback" || {
    pf_vm_lifecycle_abort "Could not persist operation manifest."
    return 1
  }
  details=$(jq -cn --arg name "$vm_name" --arg storage "$storage" --arg bridge "$bridge" --argjson vmid "$vmid" \
    '{vmid:$vmid,vm_name:$name,storage:$storage,bridge:$bridge}') || details='{}'
  pf_vm_lifecycle_event VM_CREATE_INTENT VM_CREATING INTENT "Create managed virtual machine" "$details" || {
    pf_vm_lifecycle_abort "Could not journal VM creation intent."
    return 1
  }

  PF_VM_MUTATION_STARTED=true
  if ! pf_pve_vm_create "$vmid" "$vm_name" "$storage" "$bridge" "$profile_json"; then
    if [[ "$PF_PVE_CREATED_VM_ID" == "$vmid" ]]; then
      vm_resource=$(pf_vm_lifecycle_vm_resource "$vmid" "$PF_PVE_NODE" false) || vm_resource=""
      [[ -n "$vm_resource" ]] && pf_vm_lifecycle_add_resource "$vm_resource" || true
    fi
    pf_vm_lifecycle_abort "VM creation failed or could not be verified; manual reconciliation is required."
    return 1
  fi
  vm_resource=$(pf_vm_lifecycle_vm_resource "$vmid" "$PF_PVE_NODE" true) || { pf_vm_lifecycle_abort "Could not record VM ownership."; return 1; }
  pf_vm_lifecycle_add_resource "$vm_resource" || { pf_vm_lifecycle_abort "VM exists but its resource record could not be persisted."; return 1; }
  efi_volid=$(jq -r '.efidisk0 // empty | split(",")[0]' <<< "$PF_PVE_CREATED_VM_JSON") || { pf_vm_lifecycle_abort "Could not identify the EFI volume."; return 1; }
  efi_storage=$(cut -d ':' -f 1 <<< "$efi_volid")
  [[ -n "$efi_volid" && "$efi_storage" == "$storage" ]] || { pf_vm_lifecycle_abort "EFI volume identity is missing or points to unexpected storage."; return 1; }
  efi_resource=$(jq -cn --arg volid "$efi_volid" --arg storage "$efi_storage" --arg node "$PF_PVE_NODE" --arg timestamp "$(pf_vm_lifecycle_now)" --argjson vmid "$vmid" '
    {resource_type:"efi",volid:$volid,storage:$storage,slot:"efidisk0",role:"efi",vmid:$vmid,node:$node,created_at:$timestamp,ownership_verified:true}
  ') || { pf_vm_lifecycle_abort "Could not create EFI ownership record."; return 1; }
  pf_vm_lifecycle_add_resource "$efi_resource" || { pf_vm_lifecycle_abort "EFI ownership record could not be persisted."; return 1; }
  pf_vm_lifecycle_set_state DISK_IMPORTING || { pf_vm_lifecycle_abort "Could not persist DISK_IMPORTING state."; return 1; }
  pf_vm_lifecycle_event VM_CREATED DISK_IMPORTING SUCCESS "VM created and verified" "{}" "$(jq -cn --argjson vmid "$vmid" '{resource_type:"vm",vmid:$vmid}')" || { pf_vm_lifecycle_abort "Could not journal VM creation."; return 1; }
  # The VMID is now present in Proxmox and the allocation decision is committed.
  # Release the global lock before the potentially long disk import and configuration steps.
  flock -u 9 || true
  exec 9>&-
  PF_VM_VMID_LOCKED=false

  pf_vm_lifecycle_event DISK_IMPORT_INTENT DISK_IMPORTING INTENT "Import verified system disk" || { pf_vm_lifecycle_abort "Could not journal disk import intent."; return 1; }
  pf_pve_vm_import_disk "$vmid" "$image_path" "$storage" || {
    pf_vm_lifecycle_abort "Disk import failed or its outcome is uncertain; manual reconciliation is required."
    return 1
  }
  volume_resource=$(jq -cn --arg timestamp "$(pf_vm_lifecycle_now)" --argjson source "$PF_PVE_IMPORTED_RESOURCE_JSON" '
    $source + {resource_type:"volume",role:"system",created_at:$timestamp,ownership_verified:true}
  ') || { pf_vm_lifecycle_abort "Imported volume identity could not be recorded."; return 1; }
  pf_vm_lifecycle_add_resource "$volume_resource" || { pf_vm_lifecycle_abort "Imported volume ownership record could not be persisted."; return 1; }
  pf_vm_lifecycle_set_state VM_CONFIGURING || { pf_vm_lifecycle_abort "Could not persist VM_CONFIGURING state."; return 1; }
  pf_vm_lifecycle_event DISK_IMPORTED VM_CONFIGURING SUCCESS "System disk imported and identified" "{}" "$(jq -cn --argjson vmid "$vmid" --arg volid "$PF_PVE_IMPORTED_VOLUME" --arg storage "$storage" '{resource_type:"volume",vmid:$vmid,volid:$volid,storage:$storage}')" || { pf_vm_lifecycle_abort "Could not journal disk import."; return 1; }

  pf_vm_lifecycle_event VM_CONFIGURED VM_CONFIGURING INTENT "Attach imported system disk to scsi0" || { pf_vm_lifecycle_abort "Could not journal disk attachment intent."; return 1; }
  pf_pve_vm_attach_imported_disk "$vmid" scsi0 "$PF_PVE_IMPORTED_VOLUME" || { pf_vm_lifecycle_abort "System disk attachment failed or is uncertain."; return 1; }
  pf_vm_lifecycle_event VM_CONFIGURED VM_CONFIGURING SUCCESS "System disk attached and verified" "{}" "$(jq -cn --argjson vmid "$vmid" --arg volid "$PF_PVE_IMPORTED_VOLUME" --arg storage "$storage" '{resource_type:"volume",vmid:$vmid,volid:$volid,storage:$storage}')" || { pf_vm_lifecycle_abort "Could not journal disk attachment."; return 1; }

  pf_vm_lifecycle_set_state CLOUD_INIT_CONFIGURING || { pf_vm_lifecycle_abort "Could not persist Cloud-Init state."; return 1; }
  pf_vm_lifecycle_event CLOUD_INIT_CONFIGURED CLOUD_INIT_CONFIGURING INTENT "Configure NoCloud and DHCP" || { pf_vm_lifecycle_abort "Could not journal Cloud-Init intent."; return 1; }
  pf_pve_vm_configure_cloudinit "$vmid" "$storage" || { pf_vm_lifecycle_abort "Cloud-Init configuration failed or is uncertain."; return 1; }
  [[ "$PF_PVE_CLOUDINIT_VOLUME" == "$storage:vm-$vmid-cloudinit" ]] || {
    pf_vm_lifecycle_abort "Proxmox did not return the expected VM-owned Cloud-Init volume identifier."
    return 1
  }
  cloudinit_resource=$(jq -cn --arg storage "$storage" --arg volid "$PF_PVE_CLOUDINIT_VOLUME" --arg node "$PF_PVE_NODE" --arg timestamp "$(pf_vm_lifecycle_now)" --argjson vmid "$vmid" '
    {resource_type:"cloudinit",volid:$volid,storage:$storage,slot:"ide2",role:"cloud-init",vmid:$vmid,node:$node,created_at:$timestamp,ownership_verified:true}
  ') || { pf_vm_lifecycle_abort "Could not create Cloud-Init ownership record."; return 1; }
  pf_vm_lifecycle_add_resource "$cloudinit_resource" || { pf_vm_lifecycle_abort "Cloud-Init ownership record could not be persisted."; return 1; }
  pf_vm_lifecycle_event CLOUD_INIT_CONFIGURED CLOUD_INIT_CONFIGURING SUCCESS "Cloud-Init configuration verified" || { pf_vm_lifecycle_abort "Could not journal Cloud-Init result."; return 1; }

  start_vm=$(jq -r '.start_vm' <<< "$PF_CORE_CONFIG_JSON") || { pf_vm_lifecycle_abort "Could not read start_vm policy."; return 1; }
  if [[ "$start_vm" == "true" ]]; then
    pf_vm_lifecycle_set_state VM_STARTING || { pf_vm_lifecycle_abort "Could not persist VM_STARTING state."; return 1; }
    pf_vm_lifecycle_event VM_START_INTENT VM_STARTING INTENT "Start managed VM" || { pf_vm_lifecycle_abort "Could not journal start intent."; return 1; }
    pf_pve_vm_start "$vmid" || { pf_vm_lifecycle_abort "VM start failed or running state is uncertain."; return 1; }
    pf_vm_lifecycle_event VM_STARTED VM_STARTING SUCCESS "VM running state verified" || { pf_vm_lifecycle_abort "Could not journal VM start result."; return 1; }
  fi

  pf_vm_lifecycle_set_state COMPLETED || { pf_vm_lifecycle_abort "Could not persist completed state."; return 1; }
  details=$(jq -cn --argjson vmid "$vmid" --arg name "$vm_name" --argjson started "$start_vm" \
    '{vmid:$vmid,vm_name:$name,started:$started}') || details='{}'
  pf_vm_lifecycle_event COMPLETED COMPLETED SUCCESS "VM lifecycle completed" "$details" || { pf_vm_lifecycle_abort "Could not journal operation completion."; return 1; }
  PF_VM_OPERATION_RESULT_JSON=$(jq -cn --arg id "$PF_VM_OPERATION_ID" --arg path "$PF_VM_OPERATION_DIR" --argjson manifest "$PF_VM_MANIFEST_JSON" \
    '{operation_id:$id,operation_dir:$path,manifest:$manifest}') || { pf_vm_lifecycle_abort "Could not build operation result."; return 1; }
  printf '%s\n' "$PF_VM_OPERATION_RESULT_JSON"
  pf_vm_lifecycle_unlock
  pf_core_info "VM lifecycle completed: VMID $vmid, operation $PF_VM_OPERATION_ID."
}

pf_vm_lifecycle_operation_show() {
  local id="$1" dir
  pf_vm_lifecycle_prepare_state_root || return 1
  pf_vm_lifecycle_valid_uuid "$id" || return 1
  dir="$PF_VM_STATE_ROOT/$id"
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  if [[ -f "$dir/operation.json" && ! -L "$dir/operation.json" ]]; then
    jq . "$dir/operation.json"
  elif [[ -f "$dir/request.json" && ! -L "$dir/request.json" ]]; then
    jq -n --arg id "$id" --argjson request "$(cat "$dir/request.json")" \
      '{operation_id:$id,manifest_ready:false,request:$request}'
  else
    return 1
  fi
}

pf_vm_lifecycle_operation_list() {
  local file manifest output='[]'
  pf_vm_lifecycle_prepare_state_root || return 1
  for file in "$PF_VM_STATE_ROOT"/*/operation.json; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    manifest=$(<"$file") || return 1
    output=$(jq -c --argjson m "$manifest" '. + [{
      operation_id:$m.operation_id,state:$m.state,vmid:$m.vmid,
      distribution:$m.distribution,release:$m.release,profile:$m.profile,
      node:$m.node,rollback_status:$m.rollback_status
    }]' <<< "$output") || return 1
  done
  jq . <<< "$output"
}

pf_vm_lifecycle_reconcile() {
  local id="$1" vmid node config status managed system_disk cloudinit manifest_path
  pf_vm_lifecycle_prepare_state_root || return 1
  pf_vm_lifecycle_valid_uuid "$id" || return 1
  manifest_path="$PF_VM_STATE_ROOT/$id/operation.json"
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || return 1
  PF_VM_MANIFEST_JSON=$(<"$manifest_path") || return 1
  jq -e --arg id "$id" '.schema_version == 1 and .operation_id == $id' <<< "$PF_VM_MANIFEST_JSON" >/dev/null || return 1
  vmid=$(jq -r '.vmid' <<< "$PF_VM_MANIFEST_JSON") || return 1
  node=$(jq -r '.node' <<< "$PF_VM_MANIFEST_JSON") || return 1
  pf_pve_init || return 1
  [[ "$node" == "$PF_PVE_NODE" ]] || {
    pf_vm_lifecycle_error "Operation belongs to node '$node', not '$PF_PVE_NODE'."
    return 1
  }
  pf_pve_vm_get_config "$vmid" || {
    pf_vm_lifecycle_error "VM $vmid could not be read. No changes were made."
    return 1
  }
  config="$PF_PVE_VM_CONFIG_JSON"
  pf_pve_vm_get_status "$vmid" || return 1
  status="$PF_PVE_VM_STATUS_JSON"
  managed=$(jq -r '((.tags // "") | split(";") | index("proxforge") != null)' <<< "$config")
  system_disk=$(jq -r '((.scsi0 // "") != "")' <<< "$config")
  cloudinit=$(jq -r '((.ide2 // "") != "")' <<< "$config")
  jq -cn --arg id "$id" --arg state "$(jq -r '.state' <<< "$PF_VM_MANIFEST_JSON")" \
    --argjson vmid "$vmid" --argjson status "$status" --argjson managed "$managed" \
    --argjson system_disk "$system_disk" --argjson cloudinit "$cloudinit" '
      {operation_id:$id,vmid:$vmid,journal_state:$state,proxmox_status:$status.status,
       proxforge_managed:$managed,system_disk_present:$system_disk,cloudinit_drive_present:$cloudinit,
       automatic_resume:false,automatic_rollback:false,action_required:true}
    '
}
