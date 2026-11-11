#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
export FAKE_VM_CONFIG="$TMP_ROOT/vm-config.json"
export FAKE_VM_STATUS="$TMP_ROOT/vm-status.json"
export FAKE_VM_RESOURCES="$TMP_ROOT/vm-resources.json"
export FAKE_QM_LOG="$TMP_ROOT/qm.log"
export FAKE_DISK_PATH="$TMP_ROOT/imported-system-disk.raw"
export FAKE_DISK_SIZE_FILE="$TMP_ROOT/imported-system-disk.size"
: > "$FAKE_DISK_PATH"
printf '1073741824\n' > "$FAKE_DISK_SIZE_FILE"
export FAKE_PVE_VERSION="pve-manager/9.2.13/abcdef12"
printf '{}' > "$FAKE_VM_CONFIG"
printf '{"status":"stopped"}' > "$FAKE_VM_STATUS"
printf '[]' > "$FAKE_VM_RESOURCES"
: > "$FAKE_QM_LOG"

cat > "$MOCK_BIN/pveversion" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_PVE_VERSION"
MOCK
cat > "$MOCK_BIN/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'pve1\n'
MOCK
cat > "$MOCK_BIN/pvesh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
path="$2"
case "$path" in
  /nodes)
    printf '[{"node":"pve1","status":"online"},{"node":"pve2","status":"online"}]\n'
    ;;
  /storage)
    printf '[{"storage":"local-lvm","type":"lvmthin","content":"images,rootdir","disable":0,"shared":0}]\n'
    ;;
  /nodes/pve1/storage)
    printf '[{"storage":"local-lvm","active":1,"total":107374182400,"used":1073741824,"avail":106300000000}]\n'
    ;;
  /cluster/resources)
    cat "$FAKE_VM_RESOURCES"
    ;;
  /cluster/nextid)
    printf '"300"\n'
    ;;
  /nodes/pve1/qemu/300/config)
    cat "$FAKE_VM_CONFIG"
    ;;
  /nodes/pve1/qemu/300/status/current)
    cat "$FAKE_VM_STATUS"
    ;;
  *)
    printf 'Unexpected pvesh path: %s\n' "$path" >&2
    exit 20
    ;;
esac
MOCK
cat > "$MOCK_BIN/ip" <<'MOCK'
#!/usr/bin/env bash
printf '[{"ifname":"vmbr0","operstate":"UP","flags":["BROADCAST","UP","LOWER_UP"]}]\n'
MOCK
cat > "$MOCK_BIN/pvesm" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "path" && "${2:-}" == "local-lvm:vm-300-disk-0" ]]; then
  printf '%s\n' "$FAKE_DISK_PATH"
else
  printf 'Unexpected pvesm arguments: %s\n' "$*" >&2
  exit 22
fi
MOCK
cat > "$MOCK_BIN/qemu-img" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
image_path="${@: -1}"
if [[ "$image_path" == "$FAKE_DISK_PATH" ]]; then
  printf '{"format":"raw","virtual-size":%s}\n' "$(cat "$FAKE_DISK_SIZE_FILE")"
else
  printf '{"format":"qcow2","virtual-size":1073741824}\n'
fi
MOCK
cat > "$MOCK_BIN/qm" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FAKE_QM_LOG"
command="$1"
shift
case "$command" in
  create)
    vmid="$1"
    shift
    name="" memory="" cores="" machine="" bios="" scsihw="" net0="" agent="" efi="" tags=""
    while (($#)); do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --memory) memory="$2"; shift 2 ;;
        --cores) cores="$2"; shift 2 ;;
        --machine) machine="$2"; shift 2 ;;
        --bios) bios="$2"; shift 2 ;;
        --scsihw) scsihw="$2"; shift 2 ;;
        --net0) net0="$2"; shift 2 ;;
        --agent) agent="$2"; shift 2 ;;
        --efidisk0) efi="$2"; shift 2 ;;
        --tags) tags="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    jq -n --arg name "$name" --argjson memory "$memory" --argjson cores "$cores" \
      --arg machine "$machine" --arg bios "$bios" --arg scsihw "$scsihw" \
      --arg net0 "$net0" --arg agent "$agent" --arg efi "$efi" --arg tags "$tags" \
      '{name:$name,memory:$memory,cores:$cores,machine:$machine,bios:$bios,scsihw:$scsihw,net0:$net0,agent:$agent,efidisk0:$efi,tags:$tags}' \
      > "$FAKE_VM_CONFIG"
    jq --argjson vmid "$vmid" '. + [{vmid:$vmid,type:"qemu"}]' "$FAKE_VM_RESOURCES" > "$FAKE_VM_RESOURCES.new"
    mv "$FAKE_VM_RESOURCES.new" "$FAKE_VM_RESOURCES"
    ;;
  importdisk)
    vmid="$1"; image="$2"; storage="$3"
    volume="${storage}:vm-${vmid}-disk-0"
    jq --arg volume "$volume" '. + {unused0:$volume}' "$FAKE_VM_CONFIG" > "$FAKE_VM_CONFIG.new"
    mv "$FAKE_VM_CONFIG.new" "$FAKE_VM_CONFIG"
    : > "$FAKE_DISK_PATH"
    printf '1073741824\n' > "$FAKE_DISK_SIZE_FILE"
    ;;
  resize)
    vmid="$1"; slot="$2"; size="$3"
    [[ "$slot" == "scsi0" && "$size" =~ ^[0-9]+G$ ]] || exit 23
    size_gb="${size%G}"
    printf '%s\n' "$((size_gb * 1024 * 1024 * 1024))" > "$FAKE_DISK_SIZE_FILE"
    ;;
  set)
    vmid="$1"; shift
    while (($#)); do
      case "$1" in
        --scsi0)
          jq --arg volume "$2" '. + {scsi0:$volume} | del(.unused0)' "$FAKE_VM_CONFIG" > "$FAKE_VM_CONFIG.new"
          mv "$FAKE_VM_CONFIG.new" "$FAKE_VM_CONFIG"
          shift 2
          ;;
        --ide2)
          cloudinit_storage="${2%%:*}"
          cloudinit_volume="${cloudinit_storage}:vm-${vmid}-cloudinit,media=cdrom"
          jq --arg volume "$cloudinit_volume" '. + {ide2:$volume}' "$FAKE_VM_CONFIG" > "$FAKE_VM_CONFIG.new"
          mv "$FAKE_VM_CONFIG.new" "$FAKE_VM_CONFIG"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    ;;
  start)
    printf '{"status":"running"}\n' > "$FAKE_VM_STATUS"
    ;;
  *)
    printf 'Unexpected qm subcommand: %s\n' "$command" >&2
    exit 21
    ;;
esac
MOCK
chmod 755 "$MOCK_BIN/"*
export PATH="$MOCK_BIN:$PATH"

export PF_CORE_ROOT="$ROOT_DIR/src"
export PF_CORE_TEST_MODE=1
export PF_PVE_TEST_MODE=1
source "$ROOT_DIR/src/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"

pf_pve_init || fail "PVE 9.2 adapter initialization failed"
[[ "$PF_PVE_VERSION" == "9.2.13" ]] || fail "PVE version parser returned an unexpected value"
[[ "$PF_PVE_NODE" == "pve1" ]] || fail "Local node detection failed"
pass "Proxmox version, root/test boundary and local-node detection"

pf_pve_refresh_inventory || fail "Inventory discovery failed"
jq -e '.local_node=="pve1" and (.storages|length)==1 and (.bridges|length)==1' \
  <<< "$PF_PVE_INVENTORY_JSON" >/dev/null || fail "Inventory document is incomplete"
pf_pve_validate_storage local-lvm || fail "Active image-capable storage was rejected"
pf_pve_validate_bridge vmbr0 || fail "Active Linux bridge was rejected"
if pf_pve_validate_bridge vmbr9 >/dev/null 2>&1; then fail "Unknown bridge was accepted"; fi
pass "Node inventory, active image storage and actual Linux bridge validation"

pf_pve_next_vmid || fail "Next VMID discovery failed"
[[ "$PF_PVE_NEXT_VMID" == "300" ]] || fail "Next VMID value mismatch"
if pf_pve_vmid_is_available 99 >/dev/null 2>&1; then fail "VMID below minimum was accepted"; fi
pass "VMID bounds and next-id lookup"

PROFILE=$(<"$ROOT_DIR/src/profiles/standard.json")
pf_pve_vm_create 300 test-vm local-lvm vmbr0 "$PROFILE" || fail "VM create primitive failed"
[[ "$PF_PVE_CREATED_VM_ID" == "300" ]] || fail "Created VMID was not recorded"
[[ "$(jq -r '.status' "$FAKE_VM_STATUS")" == "stopped" ]] || fail "VM create primitive unexpectedly started the VM"
jq -e '.machine=="q35" and .bios=="ovmf" and .scsihw=="virtio-scsi-pci" and (.tags|contains("proxforge"))' \
  "$FAKE_VM_CONFIG" >/dev/null || fail "VM hardware configuration was not applied"
pf_pve_refresh_inventory || fail "Could not refresh resource list after create"
if pf_pve_vmid_is_available 300 >/dev/null 2>&1; then fail "Used VMID was accepted after VM creation"; fi
pass "VM creation applies the closed profile contract and leaves the VM stopped"

CACHE_DIR="$TMP_ROOT/cache"
mkdir -p "$CACHE_DIR"
IMAGE="$CACHE_DIR/synthetic.qcow2"
printf 'synthetic qcow2 payload for Proxmox adapter tests\n' > "$IMAGE"
digest=$(sha256sum "$IMAGE" | awk '{print $1}')
timestamp="2026-11-09T10:00:00Z"
jq -n --arg digest "$digest" --arg timestamp "$timestamp" '{
  schema_version:1,distribution:"fedora",release:"40.2",architecture:"x86_64",
  source_url:"https://images.example.test/fedora.qcow2",filename:"fedora.qcow2",
  download_format:"file",archive_format:"none",disk_format:"qcow2",
  file_size:1,checksum_algorithm:"sha256",checksum_value:$digest,
  verification_method:"signed-checksum",verification_result:true,trust_level:"signed",
  verification_date:$timestamp,publication_identifier:"40.2:fedora.qcow2",cached_at:$timestamp
}' > "$IMAGE.json"
jq --argjson size "$(stat -c '%s' "$IMAGE")" '.file_size=$size' "$IMAGE.json" > "$IMAGE.json.new"
mv "$IMAGE.json.new" "$IMAGE.json"
export PF_IMAGE_CACHE_DIR="$CACHE_DIR"
export PF_IMAGE_PATH="$IMAGE"
export PF_IMAGE_METADATA_JSON
PF_IMAGE_METADATA_JSON=$(<"$IMAGE.json")

pf_pve_vm_import_disk 300 "$IMAGE" local-lvm || fail "Verified image import primitive failed"
[[ "$PF_PVE_IMPORTED_VM_ID" == "300" && "$PF_PVE_IMPORTED_SLOT" == "unused0" ]] || fail "Imported disk identity was not captured"
[[ "$PF_PVE_IMPORTED_VOLUME" == "local-lvm:vm-300-disk-0" ]] || fail "Imported volume identifier mismatch"
grep -F "importdisk 300 $IMAGE local-lvm --format raw" "$FAKE_QM_LOG" >/dev/null ||
  fail "LVM-thin storage was not requested to receive a RAW disk"
pass "Import validates image metadata and requests RAW for LVM-thin storage"

# An existing system disk must never be silently overwritten.
jq '. + {scsi0:"local-lvm:pre-existing-system-disk"}' "$FAKE_VM_CONFIG" > "$FAKE_VM_CONFIG.new"
cp "$FAKE_VM_CONFIG" "$FAKE_VM_CONFIG.before"
mv "$FAKE_VM_CONFIG.new" "$FAKE_VM_CONFIG"
if pf_pve_vm_attach_imported_disk 300 scsi0 "$PF_PVE_IMPORTED_VOLUME" >/dev/null 2>&1; then
  fail "An existing scsi0 system disk was overwritten"
fi
mv "$FAKE_VM_CONFIG.before" "$FAKE_VM_CONFIG"

# The import result must also still be present in an unused slot.
jq '.unused0="local-lvm:some-other-volume"' "$FAKE_VM_CONFIG" > "$FAKE_VM_CONFIG.new"
mv "$FAKE_VM_CONFIG.new" "$FAKE_VM_CONFIG"
if pf_pve_vm_attach_imported_disk 300 scsi0 "$PF_PVE_IMPORTED_VOLUME" >/dev/null 2>&1; then
  fail "A volume no longer present in an unused slot was attached"
fi
jq --arg volume "$PF_PVE_IMPORTED_VOLUME" '.unused0=$volume' "$FAKE_VM_CONFIG" > "$FAKE_VM_CONFIG.new"
mv "$FAKE_VM_CONFIG.new" "$FAKE_VM_CONFIG"

pf_pve_vm_attach_imported_disk 300 scsi0 "$PF_PVE_IMPORTED_VOLUME" || fail "Imported disk attach failed"
[[ "$(jq -r '.scsi0' "$FAKE_VM_CONFIG")" == "$PF_PVE_IMPORTED_VOLUME" ]] || fail "Imported disk was not attached to scsi0"
if pf_pve_vm_attach_imported_disk 300 scsi0 local-lvm:vm-300-disk-99 >/dev/null 2>&1; then
  fail "An unrelated volume was accepted for attachment"
fi
pass "Existing scsi0 protected; only the exact current unused volume can be attached"

pf_pve_vm_resize_disk 300 scsi0 20 || fail "Profile disk resize failed"
[[ "$(cat "$FAKE_DISK_SIZE_FILE")" == "21474836480" ]] || fail "System disk was not grown to the profile's 20 GiB minimum"
[[ "$PF_PVE_SYSTEM_DISK_SIZE_BYTES" == "21474836480" ]] || fail "Resized disk size was not returned to the lifecycle"
resize_count_before=$(grep -c '^resize ' "$FAKE_QM_LOG" || true)
pf_pve_vm_resize_disk 300 scsi0 8 || fail "A profile smaller than the existing disk should remain a no-op"
resize_count_after=$(grep -c '^resize ' "$FAKE_QM_LOG" || true)
[[ "$resize_count_after" == "$resize_count_before" ]] || fail "Disk resize attempted to shrink an existing disk"
pass "Profile disk size grows the imported disk when needed and never shrinks it"

pf_pve_vm_configure_cloudinit 300 local-lvm || fail "Cloud-Init configuration failed"
[[ "$(jq -r '.ide2' "$FAKE_VM_CONFIG")" == "local-lvm:vm-300-cloudinit,media=cdrom" ]] ||
  fail "Cloud-Init drive does not match Proxmox's generated CD-ROM volume format"
[[ "$PF_PVE_CLOUDINIT_VOLUME" == "local-lvm:vm-300-cloudinit" ]] ||
  fail "Adapter did not expose the concrete Cloud-Init volume identifier"
pf_pve_vm_start 300 || fail "Explicit VM start failed"
[[ "$(jq -r '.status' "$FAKE_VM_STATUS")" == "running" ]] || fail "VM did not reach running state"
pass "Cloud-Init attachment and explicit start are read-after-write verified"

FAKE_PVE_VERSION="pve-manager/9.1.21/legacy"
export FAKE_PVE_VERSION
PF_PVE_INITIALIZED=false
if pf_pve_init >/dev/null 2>&1; then fail "Unsupported PVE 9.1 version was accepted"; fi
FAKE_PVE_VERSION="pve-manager/8.4.1/legacy"
export FAKE_PVE_VERSION
PF_PVE_INITIALIZED=false
if pf_pve_init >/dev/null 2>&1; then fail "Unsupported PVE 8.x version was accepted"; fi
pass "Proxmox versions older than 9.2 are rejected"

pass "Proxmox Adapter hermetic tests completed; no real Proxmox command or network used"
