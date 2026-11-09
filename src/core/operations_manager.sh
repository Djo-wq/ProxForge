#!/usr/bin/env bash
# ProxForge Operations Manager. Sourced by Core; no host work at source time.

PF_OPERATIONS_LOCKED_HERE=false
PF_OPERATIONS_LAST_ERROR=""

pf_operations_error() { pf_core_error "Operations Manager: $*"; }

pf_operations_valid_uuid() {
  [[ "$1" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-8][A-Fa-f0-9]{3}-[89AaBb][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]]
}

pf_operations_validate_event_log() {
  local operation_id="$1" events_file="$2"
  [[ -f "$events_file" && ! -L "$events_file" && -r "$events_file" ]] || return 1
  jq -e -s --arg id "$operation_id" '
    type == "array" and length > 0 and
    all(.[]; type == "object" and .schema_version == 1 and .operation_id == $id and
      (.sequence | type == "number" and floor == . and . >= 1) and
      (.timestamp | type == "string") and (.event | type == "string") and (.state | type == "string")) and
    ([.[].sequence] == [range(1; length + 1)])
  ' "$events_file" >/dev/null || {
    pf_operations_error "Operation journal is invalid or has a sequence gap."
    return 1
  }
  PF_VM_EVENT_SEQUENCE=$(jq -s 'length' "$events_file") || return 1
}

pf_operations_load_operation() {
  local operation_id="$1" directory manifest_file
  pf_operations_valid_uuid "$operation_id" || return 1
  directory="$PF_VM_STATE_ROOT/$operation_id"
  manifest_file="$directory/operation.json"
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  [[ -f "$manifest_file" && ! -L "$manifest_file" && -r "$manifest_file" ]] || return 1
  PF_VM_MANIFEST_JSON=$(<"$manifest_file") || return 1
  jq -e --arg id "$operation_id" '
    type == "object" and .schema_version == 1 and .operation_id == $id and
    (.created_resources | type == "array") and
    (.rollback_mode == "auto" or .rollback_mode == "keep") and
    (.vmid | type == "number" and floor == . and . >= 100) and (.node | type == "string")
  ' <<< "$PF_VM_MANIFEST_JSON" >/dev/null || return 1
  PF_VM_OPERATION_ID="$operation_id"
  PF_VM_OPERATION_DIR="$directory"
  PF_VM_MANIFEST_FILE="$manifest_file"
  PF_VM_EVENTS_FILE="$directory/events.jsonl"
  pf_operations_validate_event_log "$operation_id" "$PF_VM_EVENTS_FILE" || return 1
  PF_VM_CURRENT_STATE=$(jq -r '.state' <<< "$PF_VM_MANIFEST_JSON") || return 1
}

pf_operations_acquire_lock() {
  local operation_id="$1"
  if [[ "$PF_VM_OPERATION_LOCKED" == "true" && "$PF_VM_OPERATION_ID" == "$operation_id" ]]; then
    PF_OPERATIONS_LOCKED_HERE=false
    return 0
  fi
  exec 8> "$PF_VM_OPERATION_DIR/.lock" || return 1
  flock -n 8 || {
    exec 8>&-
    pf_operations_error "Operation is locked by another process."
    return 1
  }
  PF_VM_OPERATION_LOCKED=true
  PF_OPERATIONS_LOCKED_HERE=true
}

pf_operations_release_lock() {
  if [[ "$PF_OPERATIONS_LOCKED_HERE" == "true" ]]; then
    pf_vm_lifecycle_unlock
  fi
  PF_OPERATIONS_LOCKED_HERE=false
}

pf_operations_mark_blocked() {
  local reason="$1" details
  pf_vm_lifecycle_set_state FAILED BLOCKED || return 1
  details=$(jq -cn --arg reason "$reason" '{reason:$reason,manual_reconciliation_required:true}') || details='{}'
  pf_vm_lifecycle_event RECONCILIATION_REQUIRED FAILED FAILURE "$reason" "$details"
}

pf_operations_mark_incomplete() {
  local reason="$1" details
  pf_vm_lifecycle_set_state ROLLBACK_INCOMPLETE INCOMPLETE || return 1
  details=$(jq -cn --arg reason "$reason" '{reason:$reason,retryable_after_reconciliation:true}') || details='{}'
  pf_vm_lifecycle_event ROLLBACK_INCOMPLETE ROLLBACK_INCOMPLETE FAILURE "$reason" "$details"
}

pf_operations_validate_owned_manifest() {
  local vmid node
  vmid=$(jq -r '.vmid' <<< "$PF_VM_MANIFEST_JSON") || return 1
  node=$(jq -r '.node' <<< "$PF_VM_MANIFEST_JSON") || return 1
  jq -e --argjson vmid "$vmid" --arg node "$node" '
    (.created_resources | type == "array" and length > 0) and
    ([.created_resources[] | select(.resource_type == "vm" and .vmid == $vmid and .node == $node and .ownership_verified == true)] | length == 1) and
    all(.created_resources[]; .vmid == $vmid and .ownership_verified == true)
  ' <<< "$PF_VM_MANIFEST_JSON" >/dev/null
}

pf_operations_rollback_locked() {
  local reason="$1" automatic="$2"
  local state mode vmid node resources details resource event_resource failure_reason
  state=$(jq -r '.state' <<< "$PF_VM_MANIFEST_JSON") || return 1
  mode=$(jq -r '.rollback_mode' <<< "$PF_VM_MANIFEST_JSON") || return 1

  [[ "$state" != "COMPLETED" ]] || {
    pf_operations_mark_blocked "Completed deployments cannot be rolled back by the failure manager."
    return 1
  }
  case "$state" in
    FAILED|ROLLBACK_REQUIRED|ROLLBACK_INCOMPLETE|ROLLING_BACK) ;;
    *) pf_operations_mark_blocked "Operation state '$state' is not eligible for rollback."; return 1 ;;
  esac
  if [[ "$automatic" == "true" && "$mode" != "auto" ]]; then
    pf_operations_mark_blocked "Automatic rollback is disabled by rollback_mode=keep."
    return 1
  fi
  if ! pf_operations_validate_owned_manifest; then
    pf_operations_mark_blocked "Manifest does not prove complete resource ownership."
    return 1
  fi

  vmid=$(jq -r '.vmid' <<< "$PF_VM_MANIFEST_JSON") || return 1
  node=$(jq -r '.node' <<< "$PF_VM_MANIFEST_JSON") || return 1
  resources=$(jq -c '.created_resources' <<< "$PF_VM_MANIFEST_JSON") || return 1
  PF_VM_MUTATION_STARTED=true
  pf_vm_lifecycle_set_state ROLLING_BACK IN_PROGRESS || return 1
  details=$(jq -cn --arg reason "$reason" --argjson count "$(jq -r 'length' <<< "$resources")" \
    --argjson automatic "$automatic" '{reason:$reason,resource_count:$count,automatic:$automatic,force:false,stop_vm:false}') || details='{}'
  pf_vm_lifecycle_event ROLLBACK_INTENT ROLLING_BACK INTENT "Remove manifest-owned VM resources" "$details" || {
    pf_operations_mark_incomplete "Could not persist rollback intent."
    return 1
  }

  pf_pve_init || {
    pf_operations_mark_blocked "Proxmox preflight failed; no destructive action was attempted."
    return 1
  }
  if ! pf_pve_vm_destroy_managed "$vmid" "$node" "$resources"; then
    failure_reason="$PF_PVE_DESTROY_ERROR"
    [[ -n "$failure_reason" ]] || failure_reason="Proxmox cleanup failed."
    if [[ "$PF_PVE_DESTROY_MUTATION_STARTED" == "true" ]]; then
      pf_operations_mark_incomplete "$failure_reason"
    else
      pf_operations_mark_blocked "$failure_reason"
    fi
    return 1
  fi

  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    event_resource=$(jq -cn --argjson r "$resource" '
      {resource_type:$r.resource_type,vmid:$r.vmid} +
      (if $r.volid == null then {} else {volid:$r.volid} end) +
      (if $r.storage == null then {} else {storage:$r.storage} end)
    ') || return 1
    pf_vm_lifecycle_event RESOURCE_REMOVED ROLLING_BACK SUCCESS "Verified operation-owned resource removal" "{}" "$event_resource" || {
      pf_operations_mark_incomplete "Cleanup succeeded but a resource removal event could not be persisted."
      return 1
    }
  done < <(jq -c '.[]' <<< "$resources")

  pf_vm_lifecycle_set_state ROLLBACK_COMPLETED COMPLETED || {
    pf_operations_mark_incomplete "Cleanup succeeded but final rollback state could not be persisted."
    return 1
  }
  details=$(jq -cn --argjson vmid "$vmid" '{vmid:$vmid,vm_removed:true,owned_volumes_removed:true}') || details='{}'
  pf_vm_lifecycle_event ROLLBACK_COMPLETED ROLLBACK_COMPLETED SUCCESS "Rollback completed and resource absence verified" "$details"
}

pf_operations_handle_failure() {
  local message="$1" count mode state details
  if [[ -z "$PF_VM_MANIFEST_JSON" ]]; then
    details=$(jq -cn --arg message "$message" '{message:$message}') || details='{}'
    pf_vm_lifecycle_event FAILED "$PF_VM_CURRENT_STATE" FAILURE "$message" "$details" || true
    pf_vm_lifecycle_error "$message"
    pf_vm_lifecycle_unlock
    return 1
  fi
  count=$(jq -r '.created_resources | length' <<< "$PF_VM_MANIFEST_JSON" 2>/dev/null || printf '0')
  mode=$(jq -r '.rollback_mode // "keep"' <<< "$PF_VM_MANIFEST_JSON") || mode=keep
  state=$(jq -r '.state // "FAILED"' <<< "$PF_VM_MANIFEST_JSON") || state=FAILED

  if [[ "$state" == "COMPLETED" ]]; then
    pf_operations_mark_blocked "Completion journal failed after VM deployment; automatic rollback is intentionally disabled." || true
  elif [[ "$PF_VM_MUTATION_STARTED" != "true" && "$count" == "0" ]]; then
    pf_vm_lifecycle_set_state FAILED NOT_REQUIRED || true
    details=$(jq -cn --arg message "$message" '{message:$message,automatic_rollback:false}') || details='{}'
    pf_vm_lifecycle_event FAILED FAILED FAILURE "$message" "$details" || true
  elif [[ "$mode" == "auto" ]]; then
    # An abort can occur while the manifest is still in VM_CREATING,
    # DISK_IMPORTING or VM_CONFIGURING. Persist the terminal failure state
    # before entering the rollback state machine.
    pf_vm_lifecycle_set_state FAILED PENDING || {
      pf_operations_mark_blocked "Could not persist the deployment failure state before rollback." || true
      pf_vm_lifecycle_error "$message"
      pf_vm_lifecycle_unlock
      return 1
    }
    details=$(jq -cn --arg message "$message" '{message:$message,rollback_scheduled:true}') || details='{}'
    pf_vm_lifecycle_event FAILED FAILED FAILURE "$message" "$details" || {
      pf_operations_mark_incomplete "Could not persist the deployment failure event before rollback." || true
      pf_vm_lifecycle_error "$message"
      pf_vm_lifecycle_unlock
      return 1
    }
    pf_operations_rollback_locked "$message" true || true
  else
    pf_operations_mark_blocked "Deployment failed; rollback_mode=keep preserves its resources." || true
  fi
  pf_vm_lifecycle_error "$message"
  pf_vm_lifecycle_unlock
  return 1
}

pf_operations_rollback_operation() {
  local operation_id="$1" state status
  pf_vm_lifecycle_prepare_state_root || return 1
  pf_operations_load_operation "$operation_id" || return 1
  PF_OPERATIONS_LOCKED_HERE=false
  pf_operations_acquire_lock "$operation_id" || return 1
  if ! pf_operations_rollback_locked "Explicit rollback requested by operator." false; then
    pf_operations_release_lock
    return 1
  fi
  pf_operations_release_lock
  state=$(jq -r '.state' <<< "$PF_VM_MANIFEST_JSON") || return 1
  status=$(jq -r '.rollback_status' <<< "$PF_VM_MANIFEST_JSON") || return 1
  jq -cn --arg id "$operation_id" --arg state "$state" --arg status "$status" \
    '{operation_id:$id,state:$state,rollback_status:$status}'
}



pf_operations_resume_operation() {
  local operation_id="$1" directory request_file events_file manifest_file
  local request_json mutation_found manifest_json
  local distribution release profile storage bridge vm_name requested_vmid
  local result_file new_result

  pf_vm_lifecycle_prepare_state_root || return 1
  pf_operations_valid_uuid "$operation_id" || {
    pf_operations_error "Operation ID must be a UUID."
    return 1
  }
  directory="$PF_VM_STATE_ROOT/$operation_id"
  request_file="$directory/request.json"
  events_file="$directory/events.jsonl"
  manifest_file="$directory/operation.json"
  [[ -d "$directory" && ! -L "$directory" && -f "$request_file" && ! -L "$request_file" &&
     -f "$events_file" && ! -L "$events_file" ]] || {
    pf_operations_error "Operation request or event journal is missing or unsafe."
    return 1
  }

  # Hold the parent operation lock throughout validation and the replacement
  # deployment. The replacement takes its own lock on descriptor 8.
  exec 7> "$directory/.lock" || return 1
  if ! flock -n 7; then
    exec 7>&-
    pf_operations_error "The original operation is still active."
    return 1
  fi

  if ! pf_operations_validate_event_log "$operation_id" "$events_file"; then
    flock -u 7 || true
    exec 7>&-
    return 1
  fi
  request_json=$(<"$request_file") || {
    flock -u 7 || true
    exec 7>&-
    return 1
  }
  if ! jq -e '
    type == "object" and
    (.distribution | type == "string" and test("^[a-z][a-z0-9-]{1,31}$")) and
    (.requested_release | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")) and
    (.profile | type == "string" and test("^[a-z][a-z0-9-]{1,31}$")) and
    (.storage | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$")) and
    (.bridge | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,31}$")) and
    (.vm_name | type == "string" and length <= 63) and
    (.requested_vmid | type == "string") and
    (.requested_vmid == "auto" or (.requested_vmid | test("^[0-9]{3,9}$")))
  ' <<< "$request_json" >/dev/null; then
    flock -u 7 || true
    exec 7>&-
    pf_operations_error "Original deployment request is malformed."
    return 1
  fi

  mutation_found=$(jq -s '
    any(.[]; .event == "VM_CREATE_INTENT" or .event == "VM_CREATED" or
      .event == "DISK_IMPORT_INTENT" or .event == "DISK_IMPORTED" or
      .event == "VM_CONFIGURED" or .event == "CLOUD_INIT_CONFIGURED" or
      .event == "VM_START_INTENT" or .event == "VM_STARTED" or
      .event == "ROLLBACK_INTENT" or .event == "RESOURCE_REMOVED" or
      .event == "ROLLBACK_COMPLETED")
  ' "$events_file") || {
    flock -u 7 || true
    exec 7>&-
    return 1
  }
  if [[ "$mutation_found" != "false" ]]; then
    flock -u 7 || true
    exec 7>&-
    pf_operations_error "Resume refused: a VM mutation intent or result exists in the original journal."
    return 1
  fi

  if [[ -e "$manifest_file" ]]; then
    [[ -f "$manifest_file" && ! -L "$manifest_file" && -r "$manifest_file" ]] || {
      flock -u 7 || true
      exec 7>&-
      pf_operations_error "Existing operation manifest is unsafe."
      return 1
    }
    manifest_json=$(<"$manifest_file") || {
      flock -u 7 || true
      exec 7>&-
      return 1
    }
    if ! jq -e --arg id "$operation_id" '
      type == "object" and .schema_version == 1 and .operation_id == $id and
      (.created_resources | type == "array" and length == 0) and
      (.state != "COMPLETED" and .state != "ROLLBACK_COMPLETED" and
       .state != "ROLLING_BACK" and .state != "ROLLBACK_INCOMPLETE")
    ' <<< "$manifest_json" >/dev/null; then
      flock -u 7 || true
      exec 7>&-
      pf_operations_error "Resume refused: manifest is terminal, has resources, or does not match the operation directory."
      return 1
    fi
  fi

  distribution=$(jq -r '.distribution' <<< "$request_json") || return 1
  release=$(jq -r '.requested_release' <<< "$request_json") || return 1
  profile=$(jq -r '.profile' <<< "$request_json") || return 1
  storage=$(jq -r '.storage' <<< "$request_json") || return 1
  bridge=$(jq -r '.bridge' <<< "$request_json") || return 1
  vm_name=$(jq -r '.vm_name' <<< "$request_json") || return 1
  requested_vmid=$(jq -r '.requested_vmid' <<< "$request_json") || return 1

  result_file=$(mktemp "$PF_VM_STATE_ROOT/.resume-result.XXXXXX") || {
    flock -u 7 || true
    exec 7>&-
    return 1
  }
  PF_VM_OPERATION_ID=""
  PF_VM_PARENT_OPERATION_ID="$operation_id"
  PF_VM_OPERATION_RESULT_JSON=""
  if pf_vm_lifecycle_deploy "$distribution" "$release" "$profile" "$storage" "$bridge" \
    "$vm_name" "$requested_vmid" > "$result_file"; then
    new_result=$(<"$result_file") || new_result=""
    rm -f -- "$result_file"
    PF_VM_PARENT_OPERATION_ID=""
    flock -u 7 || true
    exec 7>&-
    [[ -n "$new_result" ]] || {
      pf_operations_error "Replacement deployment completed but returned no result document."
      return 1
    }
    jq -cn --arg parent "$operation_id" --argjson operation "$new_result" '
      {resumed_from:$parent,new_operation:$operation}
    '
  else
    rm -f -- "$result_file"
    PF_VM_PARENT_OPERATION_ID=""
    flock -u 7 || true
    exec 7>&-
    return 1
  fi
}
