#!/usr/bin/env bash
# ProxForge Proxmox VE Adapter. Sourced by Core; no host commands at source time.
PF_PVE_INITIALIZED=false
PF_PVE_VERSION=""
PF_PVE_NODE="${PF_PVE_NODE:-}"
PF_PVE_NODES_JSON="[]"
PF_PVE_STORAGES_JSON="[]"
PF_PVE_BRIDGES_JSON="[]"
PF_PVE_RESOURCES_JSON="[]"
PF_PVE_INVENTORY_JSON="{}"
PF_PVE_API_RESULT_JSON="null"
PF_PVE_VM_CONFIG_JSON="{}"
PF_PVE_VM_STATUS_JSON="{}"
PF_PVE_CREATED_VM_ID=""
PF_PVE_CREATED_VM_JSON="{}"
PF_PVE_IMPORTED_VM_ID=""
PF_PVE_IMPORTED_VOLUME=""
PF_PVE_IMPORTED_SLOT=""
PF_PVE_IMPORTED_RESOURCE_JSON="{}"
PF_PVE_IMAGE_METADATA_JSON="{}"
PF_PVE_IMAGE_FORMAT=""

pf_pve_error() { pf_core_error "Proxmox Adapter: $*"; }

pf_pve_valid_vmid() {
  [[ "${1:-}" =~ ^[0-9]{3,9}$ ]] || return 1
  (( 10#${1} >= 100 && 10#${1} <= 999999999 ))
}
pf_pve_valid_node() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ && "${1:-}" != *..* ]]; }
pf_pve_valid_storage_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$ ]]; }
pf_pve_valid_bridge() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,31}$ ]]; }
pf_pve_valid_vm_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]]; }

pf_pve_require_root() {
  if [[ "${PF_PVE_TEST_MODE:-0}" != "1" && "$EUID" != "0" ]]; then
    pf_pve_error "Proxmox operations must run as root on a Proxmox VE node."
    return 1
  fi
}

pf_pve_api_get() {
  local api_path="$1" raw
  shift
  [[ "$api_path" == /* && "$api_path" != *".."* ]] || {
    pf_pve_error "Unsafe Proxmox API path."
    return 1
  }
  raw=$(pvesh get "$api_path" "$@" --output-format json) || {
    pf_pve_error "Proxmox API read failed: $api_path"
    return 1
  }
  PF_PVE_API_RESULT_JSON=$(jq -ce 'if type == "object" and has("data") then .data else . end' <<< "$raw") || {
    pf_pve_error "Proxmox API returned invalid JSON for $api_path."
    return 1
  }
}

pf_pve_init() {
  local version_output major minor patch local_node command_name
  local -a required_commands=(pveversion pvesh qm pvesm qemu-img ip hostname jq stat sha256sum sha512sum)
  pf_pve_require_root || return 1
  for command_name in "${required_commands[@]}"; do
    pf_core_require_command "$command_name" || return 1
  done

  version_output=$(pveversion) || {
    pf_pve_error "Could not read the installed Proxmox VE version."
    return 1
  }
  if [[ "$version_output" =~ pve-manager/([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
  else
    pf_pve_error "Could not parse pve-manager version from pveversion output."
    return 1
  fi
  if (( major < 9 || (major == 9 && minor < 2) )); then
    pf_pve_error "Proxmox VE 9.2 or newer is required; found $major.$minor.$patch."
    return 1
  fi
  PF_PVE_VERSION="$major.$minor.$patch"

  pf_pve_api_get /nodes || return 1
  PF_PVE_NODES_JSON="$PF_PVE_API_RESULT_JSON"
  if [[ -n "${PF_PVE_NODE:-}" ]]; then
    local_node="$PF_PVE_NODE"
  else
    local_node=$(hostname -s) || return 1
  fi
  pf_pve_valid_node "$local_node" || {
    pf_pve_error "Invalid local node identifier."
    return 1
  }
  jq -e --arg node "$local_node" '
    type == "array" and any(.[]; .node == $node and .status == "online")
  ' <<< "$PF_PVE_NODES_JSON" >/dev/null || {
    pf_pve_error "Local node '$local_node' is not present and online in the Proxmox cluster."
    return 1
  }
  PF_PVE_NODE="$local_node"
  PF_PVE_INITIALIZED=true
  pf_core_info "Connected to Proxmox VE $PF_PVE_VERSION on node $PF_PVE_NODE."
}

pf_pve_require_initialized() {
  [[ "$PF_PVE_INITIALIZED" == "true" ]] || {
    pf_pve_error "Call pf_pve_init before using the adapter."
    return 1
  }
  pf_pve_require_root
}

pf_pve_refresh_inventory() {
  local definitions stats links
  pf_pve_require_initialized || return 1
  pf_pve_api_get /nodes || return 1
  PF_PVE_NODES_JSON="$PF_PVE_API_RESULT_JSON"
  pf_pve_api_get /storage || return 1
  definitions="$PF_PVE_API_RESULT_JSON"
  pf_pve_api_get "/nodes/$PF_PVE_NODE/storage" || return 1
  stats="$PF_PVE_API_RESULT_JSON"
  pf_pve_api_get /cluster/resources --type vm || return 1
  PF_PVE_RESOURCES_JSON="$PF_PVE_API_RESULT_JSON"

  PF_PVE_STORAGES_JSON=$(jq -cn --argjson definitions "$definitions" --argjson stats "$stats" '
    if ($definitions | type) != "array" or ($stats | type) != "array" then
      error("storage inventory must be arrays")
    else
      [
        $stats[] as $s |
        ($definitions[] | select(.storage == $s.storage)) as $d |
        {
          storage: $s.storage,
          type: ($d.type // $s.type // "unknown"),
          content: ($d.content // ""),
          enabled: ((($d.disable // 0) | tostring) != "1"),
          active: (((($s.active // 0) | tostring) == "1") or (($s.active // false) == true)),
          shared: (((($d.shared // 0) | tostring) == "1") or (($d.shared // false) == true)),
          total_bytes: ($s.total // 0),
          used_bytes: ($s.used // 0),
          available_bytes: ($s.avail // 0)
        }
      ]
    end
  ') || {
    pf_pve_error "Could not combine Proxmox storage definitions and node status."
    return 1
  }

  links=$(ip -j link show type bridge) || {
    pf_pve_error "Could not inspect Linux bridge interfaces on this node."
    return 1
  }
  PF_PVE_BRIDGES_JSON=$(jq -ce '
    if type != "array" then
      error("bridge inventory must be an array")
    else
      [.[] | select(.ifname | type == "string") |
        {iface:.ifname,active:((.operstate == "UP") or ((.flags // []) | index("UP") != null))}]
    end
  ' <<< "$links") || {
    pf_pve_error "Linux bridge inspection returned invalid JSON."
    return 1
  }

  PF_PVE_INVENTORY_JSON=$(jq -cn \
    --arg version "$PF_PVE_VERSION" --arg node "$PF_PVE_NODE" \
    --argjson nodes "$PF_PVE_NODES_JSON" --argjson storages "$PF_PVE_STORAGES_JSON" \
    --argjson bridges "$PF_PVE_BRIDGES_JSON" --argjson resources "$PF_PVE_RESOURCES_JSON" '
      {schema_version:1,proxmox_version:$version,local_node:$node,nodes:$nodes,
       storages:$storages,bridges:$bridges,virtual_machines_and_containers:$resources}
    ') || return 1
}

pf_pve_validate_storage() {
  local storage="$1"
  pf_pve_valid_storage_id "$storage" || {
    pf_pve_error "Invalid storage identifier."
    return 1
  }
  [[ -n "$PF_PVE_STORAGES_JSON" ]] || pf_pve_refresh_inventory || return 1
  jq -e --arg storage "$storage" '
    type == "array" and
    any(.[]; .storage == $storage and .enabled == true and .active == true and
      ((.content | split(",")) | index("images") != null))
  ' <<< "$PF_PVE_STORAGES_JSON" >/dev/null || {
    pf_pve_error "Storage '$storage' is not active and enabled for VM images on node $PF_PVE_NODE."
    return 1
  }
}

pf_pve_validate_bridge() {
  local bridge="$1"
  pf_pve_valid_bridge "$bridge" || {
    pf_pve_error "Invalid Linux bridge identifier."
    return 1
  }
  [[ -n "$PF_PVE_BRIDGES_JSON" ]] || pf_pve_refresh_inventory || return 1
  jq -e --arg bridge "$bridge" 'type == "array" and any(.[]; .iface == $bridge and .active == true)' \
    <<< "$PF_PVE_BRIDGES_JSON" >/dev/null || {
    pf_pve_error "Linux bridge '$bridge' does not exist or is not UP on node $PF_PVE_NODE."
    return 1
  }
}

pf_pve_vmid_is_available() {
  local vmid="$1"
  pf_pve_valid_vmid "$vmid" || {
    pf_pve_error "VMID must be an integer between 100 and 999999999."
    return 1
  }
  [[ -n "$PF_PVE_RESOURCES_JSON" ]] || pf_pve_refresh_inventory || return 1
  jq -e 'type == "array" and all(.[]; type == "object" and has("vmid"))' \
    <<< "$PF_PVE_RESOURCES_JSON" >/dev/null || {
    pf_pve_error "Cluster guest inventory is malformed; refusing to treat a VMID as available."
    return 1
  }
  if jq -e --argjson vmid "$vmid" 'any(.[]; (.vmid | tonumber?) == $vmid)' \
    <<< "$PF_PVE_RESOURCES_JSON" >/dev/null; then
    pf_pve_error "VMID $vmid is already used by a VM or container in the cluster."
    return 1
  fi
}

pf_pve_next_vmid() {
  local value candidate
  pf_pve_require_initialized || return 1
  pf_pve_api_get /cluster/nextid || return 1
  value="$PF_PVE_API_RESULT_JSON"
  candidate=$(jq -er '
    if type == "number" then .
    elif type == "string" and test("^[0-9]{3,9}$") then tonumber
    elif type == "object" and (.vmid | tostring | test("^[0-9]{3,9}$")) then (.vmid | tonumber)
    else error("unexpected nextid response") end
  ' <<< "$value") || {
    pf_pve_error "Proxmox returned an invalid next VMID."
    return 1
  }
  pf_pve_valid_vmid "$candidate" || return 1
  PF_PVE_RESOURCES_JSON=""
  pf_pve_refresh_inventory || return 1
  pf_pve_vmid_is_available "$candidate" || return 1
  PF_PVE_NEXT_VMID="$candidate"
}

pf_pve_vm_get_config() {
  local vmid="$1"
  pf_pve_valid_vmid "$vmid" || return 1
  pf_pve_require_initialized || return 1
  pf_pve_api_get "/nodes/$PF_PVE_NODE/qemu/$vmid/config" || return 1
  [[ "$(jq -r 'type' <<< "$PF_PVE_API_RESULT_JSON")" == "object" ]] || {
    pf_pve_error "VM $vmid configuration response is not an object."
    return 1
  }
  PF_PVE_VM_CONFIG_JSON="$PF_PVE_API_RESULT_JSON"
}

pf_pve_vm_get_status() {
  local vmid="$1"
  pf_pve_valid_vmid "$vmid" || return 1
  pf_pve_require_initialized || return 1
  pf_pve_api_get "/nodes/$PF_PVE_NODE/qemu/$vmid/status/current" || return 1
  [[ "$(jq -r 'type' <<< "$PF_PVE_API_RESULT_JSON")" == "object" ]] || return 1
  PF_PVE_VM_STATUS_JSON="$PF_PVE_API_RESULT_JSON"
}

pf_pve_vm_is_managed() {
  local vmid="$1"
  pf_pve_vm_get_config "$vmid" || return 1
  jq -e '(.tags // "") | split(";") | index("proxforge") != null' \
    <<< "$PF_PVE_VM_CONFIG_JSON" >/dev/null || {
    pf_pve_error "VM $vmid is not tagged as ProxForge-managed; refusing to modify it."
    return 1
  }
}

pf_pve_vm_create() {
  local vmid="$1" name="$2" storage="$3" bridge="$4" profile_json="$5"
  local memory cores machine firmware scsi agent secure_boot efi_value net_value
  pf_pve_require_initialized || return 1
  pf_pve_valid_vmid "$vmid" || {
    pf_pve_error "Invalid VMID."
    return 1
  }
  pf_pve_valid_vm_name "$name" || {
    pf_pve_error "VM name contains unsupported characters or is too long."
    return 1
  }
  pf_core_validate_profile_json "$profile_json" || {
    pf_pve_error "Hardware profile does not match the ProxForge profile contract."
    return 1
  }

  pf_pve_refresh_inventory || return 1
  pf_pve_vmid_is_available "$vmid" || return 1
  pf_pve_validate_storage "$storage" || return 1
  pf_pve_validate_bridge "$bridge" || return 1
  memory=$(jq -r '.memory_mb' <<< "$profile_json") || return 1
  cores=$(jq -r '.cpu_cores' <<< "$profile_json") || return 1
  machine=$(jq -r '.machine' <<< "$profile_json") || return 1
  firmware=$(jq -r '.firmware' <<< "$profile_json") || return 1
  scsi=$(jq -r '.scsi_controller' <<< "$profile_json") || return 1
  agent=$(jq -r '.agent_enabled' <<< "$profile_json") || return 1
  secure_boot=$(jq -r '.secure_boot' <<< "$profile_json") || return 1
  [[ "$memory" =~ ^[0-9]+$ && "$cores" =~ ^[0-9]+$ ]] || return 1
  [[ "$agent" == "true" || "$agent" == "false" ]] || return 1
  [[ "$secure_boot" == "true" || "$secure_boot" == "false" ]] || return 1
  [[ "$agent" == "true" ]] && agent=1 || agent=0
  [[ "$secure_boot" == "true" ]] && efi_value=1 || efi_value=0
  net_value="virtio,bridge=$bridge"

  if ! qm create "$vmid" --name "$name" --memory "$memory" --cores "$cores" \
    --machine "$machine" --bios "$firmware" --scsihw "$scsi" \
    --net0 "$net_value" --agent "enabled=$agent" \
    --efidisk0 "$storage:1,efitype=4m,pre-enrolled-keys=$efi_value" \
    --onboot 0 --tags proxforge --description "Managed by ProxForge"; then
    pf_pve_error "qm create failed for VMID $vmid. The node was not automatically cleaned up; inspect it before retrying."
    return 1
  fi
  PF_PVE_CREATED_VM_ID="$vmid"
  if ! pf_pve_vm_get_config "$vmid"; then
    pf_pve_error "VM $vmid may have been created, but its configuration could not be verified. Manual reconciliation is required."
    return 1
  fi
  if ! jq -e --arg name "$name" --argjson memory "$memory" --argjson cores "$cores" \
    --arg machine "$machine" --arg bios "$firmware" --arg scsi "$scsi" \
    --arg bridge "$bridge" --arg storage "$storage" --argjson agent "$agent" --argjson efi "$efi_value" '
      .name == $name and .memory == $memory and .cores == $cores and
      .machine == $machine and .bios == $bios and .scsihw == $scsi and
      (.net0 | type == "string" and contains("virtio") and contains("bridge=" + $bridge)) and
      (.agent | type == "string" and contains("enabled=" + ($agent|tostring))) and
      (.efidisk0 | type == "string" and startswith($storage + ":") and contains("pre-enrolled-keys=" + ($efi|tostring))) and
      ((.tags // "") | split(";") | index("proxforge") != null)
    ' <<< "$PF_PVE_VM_CONFIG_JSON" >/dev/null; then
    PF_PVE_CREATED_VM_ID="$vmid"
    PF_PVE_CREATED_VM_JSON="$PF_PVE_VM_CONFIG_JSON"
    pf_pve_error "VM $vmid was created, but read-after-write verification did not match the requested configuration. Manual reconciliation is required."
    return 1
  fi
  PF_PVE_CREATED_VM_ID="$vmid"
  PF_PVE_CREATED_VM_JSON="$PF_PVE_VM_CONFIG_JSON"
  pf_core_info "Created and verified ProxForge VM $vmid on $PF_PVE_NODE (not started)."
}

pf_pve_validate_cached_image() {
  local image_path="$1" metadata_file metadata_json file_size algorithm expected actual info format max_bytes
  [[ -n "${PF_IMAGE_PATH:-}" && "$image_path" == "$PF_IMAGE_PATH" ]] || {
    pf_pve_error "Image path was not returned by the Image Manager in this process."
    return 1
  }
  [[ -n "${PF_IMAGE_CACHE_DIR:-}" && "$image_path" == "$PF_IMAGE_CACHE_DIR/"* ]] || {
    pf_pve_error "Image is outside the configured verified cache."
    return 1
  }
  [[ -f "$image_path" && ! -L "$image_path" ]] || {
    pf_pve_error "Cached image is missing or is a symbolic link."
    return 1
  }
  metadata_file="$image_path.json"
  [[ -f "$metadata_file" && ! -L "$metadata_file" && -r "$metadata_file" ]] || {
    pf_pve_error "Verified image metadata sidecar is missing or unsafe."
    return 1
  }
  metadata_json=$(<"$metadata_file") || return 1
  [[ "$(jq -c . <<< "$metadata_json" 2>/dev/null)" == "$(jq -c . <<< "${PF_IMAGE_METADATA_JSON:-null}" 2>/dev/null)" ]] || {
    pf_pve_error "Image metadata does not match the Image Manager result from this process."
    return 1
  }
  jq -e '
    type == "object" and
    (keys - ["schema_version","distribution","release","architecture","source_url","filename",
      "download_format","archive_format","disk_format","file_size","checksum_algorithm",
      "checksum_value","verification_method","verification_result","trust_level",
      "verification_date","publication_identifier","cached_at"] | length == 0) and
    .schema_version == 1 and
    (.distribution | type == "string" and test("^[a-z][a-z0-9-]{1,31}$")) and
    (.release | type == "string" and length > 0 and length <= 64) and
    .architecture == "x86_64" and
    (.source_url | type == "string" and startswith("https://")) and
    (.filename | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
    .download_format == "file" and .archive_format == "none" and
    (.disk_format == "raw" or .disk_format == "qcow2") and
    (.file_size | type == "number" and floor == . and . > 0) and
    ((.checksum_algorithm == "sha256" and (.checksum_value | test("^[a-f0-9]{64}$"))) or
     (.checksum_algorithm == "sha512" and (.checksum_value | test("^[a-f0-9]{128}$")))) and
    .verification_result == true and
    ((.verification_method == "signed-checksum" and .trust_level == "signed") or
     (.verification_method == "official-tls-checksum" and .trust_level == "official_tls")) and
    (.verification_date | type == "string" and length >= 20) and
    (.publication_identifier | type == "string" and length > 0) and
    (.cached_at | type == "string" and length >= 20)
  ' <<< "$metadata_json" >/dev/null || {
    pf_pve_error "Cached image metadata does not match the verified-image contract."
    return 1
  }

  algorithm=$(jq -r '.checksum_algorithm' <<< "$metadata_json") || return 1
  expected=$(jq -r '.checksum_value' <<< "$metadata_json") || return 1
  format=$(jq -r '.disk_format' <<< "$metadata_json") || return 1
  file_size=$(stat -c '%s' "$image_path") || return 1
  max_bytes=$(jq -r '.image_max_bytes' <<< "$PF_CORE_CONFIG_JSON") || return 1
  (( file_size > 0 && file_size == $(jq -r '.file_size' <<< "$metadata_json") && file_size <= max_bytes )) || {
    pf_pve_error "Cached image file size does not match its metadata or configured limit."
    return 1
  }
  case "$algorithm" in
    sha256) actual=$(sha256sum -- "$image_path") || return 1 ;;
    sha512) actual=$(sha512sum -- "$image_path") || return 1 ;;
    *) return 1 ;;
  esac
  actual="${actual%% *}"
  [[ "$actual" == "$expected" ]] || {
    pf_pve_error "Cached image digest changed after Image Manager verification."
    return 1
  }
  info=$(qemu-img info --output=json "$image_path") || return 1
  jq -e --arg format "$format" '
    type == "object" and .format == $format and
    (.["virtual-size"] | type == "number" and floor == . and . > 0)
  ' <<< "$info" >/dev/null || {
    pf_pve_error "Actual disk image format does not match the verified metadata."
    return 1
  }
  if [[ "$(jq -r '.trust_level' <<< "$metadata_json")" == "official_tls" &&
        "$(jq -r '.allow_official_tls_checksum' <<< "$PF_CORE_CONFIG_JSON")" != "true" ]]; then
    pf_pve_error "Official-TLS checksum policy is now disabled; refusing import."
    return 1
  fi
  PF_PVE_IMAGE_METADATA_JSON="$metadata_json"
  PF_PVE_IMAGE_FORMAT="$format"
}

pf_pve_vm_import_disk() {
  local vmid="$1" image_path="$2" storage="$3"
  local config_before before_keys new_entries new_volume new_slot
  pf_pve_require_initialized || return 1
  pf_pve_valid_vmid "$vmid" || return 1
  pf_pve_vm_is_managed "$vmid" || return 1
  pf_pve_validate_storage "$storage" || return 1
  pf_pve_vm_get_status "$vmid" || return 1
  [[ "$(jq -r '.status // empty' <<< "$PF_PVE_VM_STATUS_JSON")" == "stopped" ]] || {
    pf_pve_error "VM $vmid must be stopped before importing its system disk."
    return 1
  }
  pf_pve_validate_cached_image "$image_path" || return 1
  config_before="$PF_PVE_VM_CONFIG_JSON"
  before_keys=$(jq -c '[keys[] | select(test("^unused[0-9]+$"))]' <<< "$config_before") || return 1
  if ! qm importdisk "$vmid" "$image_path" "$storage" --format "$PF_PVE_IMAGE_FORMAT"; then
    pf_pve_error "qm importdisk failed for VM $vmid. Any partial volume is left untouched for reconciliation."
    return 1
  fi
  pf_pve_vm_get_config "$vmid" || {
    pf_pve_error "Disk import may have completed but VM configuration could not be re-read."
    return 1
  }
  new_entries=$(jq -c --argjson before "$before_keys" '
    [to_entries[] as $entry |
      select($entry.key | test("^unused[0-9]+$")) |
      select(($before | index($entry.key)) == null) | $entry]
  ' <<< "$PF_PVE_VM_CONFIG_JSON") || return 1
  [[ "$(jq -r 'length' <<< "$new_entries")" == "1" ]] || {
    pf_pve_error "Expected exactly one new unused disk after import; found $(jq -r 'length' <<< "$new_entries"). Nothing was attached automatically."
    return 1
  }
  new_slot=$(jq -r '.[0].key' <<< "$new_entries") || return 1
  new_volume=$(jq -r '.[0].value | split(",")[0]' <<< "$new_entries") || return 1
  [[ "$new_volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}:[A-Za-z0-9_./+-]+$ && "$new_volume" != *"/../"* ]] || {
    pf_pve_error "Proxmox returned an unexpected volume identifier after import."
    return 1
  }
  [[ "${new_volume%%:*}" == "$storage" ]] || {
    pf_pve_error "Imported volume was created on an unexpected storage."
    return 1
  }
  PF_PVE_IMPORTED_VM_ID="$vmid"
  PF_PVE_IMPORTED_VOLUME="$new_volume"
  PF_PVE_IMPORTED_SLOT="$new_slot"
  PF_PVE_IMPORTED_RESOURCE_JSON=$(jq -cn \
    --arg volume "$new_volume" --arg storage "$storage" --arg slot "$new_slot" \
    --argjson vmid "$vmid" --arg node "$PF_PVE_NODE" '
      {resource_type:"volume",volid:$volume,storage:$storage,slot:$slot,vmid:$vmid,node:$node,ownership_verified:true}
    ')
  pf_core_info "Imported and verified image for VM $vmid as $new_volume (still unattached)."
}

pf_pve_vm_attach_imported_disk() {
  local vmid="$1" slot="$2" volume="$3" config_value
  pf_pve_require_initialized || return 1
  pf_pve_valid_vmid "$vmid" || return 1
  [[ "$slot" == "scsi0" ]] || {
    pf_pve_error "Phase 4 only attaches the imported system disk to scsi0."
    return 1
  }
  [[ "$PF_PVE_IMPORTED_VM_ID" == "$vmid" && "$PF_PVE_IMPORTED_VOLUME" == "$volume" && -n "$volume" ]] || {
    pf_pve_error "Disk is not the exact volume returned by pf_pve_vm_import_disk in this process."
    return 1
  }
  pf_pve_vm_is_managed "$vmid" || return 1
  pf_pve_vm_get_status "$vmid" || return 1
  [[ "$(jq -r '.status // empty' <<< "$PF_PVE_VM_STATUS_JSON")" == "stopped" ]] || {
    pf_pve_error "VM $vmid must be stopped before attaching its system disk."
    return 1
  }
  if ! jq -e --arg volume "$volume" '
    ((.scsi0 // "") == "") and
    any(to_entries[];
      (.key | test("^unused[0-9]+$")) and
      (.value | type == "string" and (split(",")[0] == $volume))
    )
  ' <<< "$PF_PVE_VM_CONFIG_JSON" >/dev/null; then
    pf_pve_error "VM $vmid already has scsi0 configured or no longer contains the exact imported volume as an unused disk."
    return 1
  fi
  qm set "$vmid" "--$slot" "$volume" || {
    pf_pve_error "Could not attach imported volume $volume to VM $vmid."
    return 1
  }
  pf_pve_vm_get_config "$vmid" || return 1
  config_value=$(jq -r --arg slot "$slot" '.[$slot] // empty | split(",")[0]' <<< "$PF_PVE_VM_CONFIG_JSON") || return 1
  [[ "$config_value" == "$volume" ]] || {
    pf_pve_error "Read-after-write verification failed for $slot on VM $vmid."
    return 1
  }
  PF_PVE_IMPORTED_SLOT="$slot"
  pf_core_info "Verified $volume attached to VM $vmid at $slot."
}

pf_pve_vm_configure_cloudinit() {
  local vmid="$1" storage="$2" config_value
  pf_pve_require_initialized || return 1
  pf_pve_valid_vmid "$vmid" || return 1
  pf_pve_vm_is_managed "$vmid" || return 1
  pf_pve_validate_storage "$storage" || return 1
  pf_pve_vm_get_status "$vmid" || return 1
  [[ "$(jq -r '.status // empty' <<< "$PF_PVE_VM_STATUS_JSON")" == "stopped" ]] || {
    pf_pve_error "VM $vmid must be stopped before configuring Cloud-Init."
    return 1
  }
  pf_pve_vm_get_config "$vmid" || return 1
  [[ -n "$(jq -r '.scsi0 // empty' <<< "$PF_PVE_VM_CONFIG_JSON")" ]] || {
    pf_pve_error "VM $vmid has no verified system disk attached to scsi0."
    return 1
  }
  qm set "$vmid" --ide2 "$storage:cloudinit" --citype nocloud --ipconfig0 ip=dhcp || {
    pf_pve_error "Could not attach Cloud-Init drive to VM $vmid."
    return 1
  }
  pf_pve_vm_get_config "$vmid" || return 1
  config_value=$(jq -r '.ide2 // empty' <<< "$PF_PVE_VM_CONFIG_JSON") || return 1
  [[ "$config_value" == "$storage:cloudinit" ]] || {
    pf_pve_error "Read-after-write verification failed for Cloud-Init drive on VM $vmid."
    return 1
  }
  pf_core_info "Verified Cloud-Init drive on VM $vmid."
}

pf_pve_vm_start() {
  local vmid="$1"
  pf_pve_require_initialized || return 1
  pf_pve_valid_vmid "$vmid" || return 1
  pf_pve_vm_is_managed "$vmid" || return 1
  pf_pve_vm_get_config "$vmid" || return 1
  [[ -n "$(jq -r '.scsi0 // empty' <<< "$PF_PVE_VM_CONFIG_JSON")" ]] || {
    pf_pve_error "VM $vmid has no system disk; refusing to start."
    return 1
  }
  [[ -n "$(jq -r '.ide2 // empty' <<< "$PF_PVE_VM_CONFIG_JSON")" ]] || {
    pf_pve_error "VM $vmid has no Cloud-Init drive; refusing to start."
    return 1
  }
  pf_pve_vm_get_status "$vmid" || return 1
  [[ "$(jq -r '.status // empty' <<< "$PF_PVE_VM_STATUS_JSON")" == "stopped" ]] || {
    pf_pve_error "VM $vmid is not stopped."
    return 1
  }
  qm start "$vmid" || {
    pf_pve_error "qm start failed for VM $vmid."
    return 1
  }
  pf_pve_vm_get_status "$vmid" || return 1
  [[ "$(jq -r '.status // empty' <<< "$PF_PVE_VM_STATUS_JSON")" == "running" ]] || {
    pf_pve_error "VM $vmid start was requested but running state was not verified."
    return 1
  }
  pf_core_info "VM $vmid is running."
}
