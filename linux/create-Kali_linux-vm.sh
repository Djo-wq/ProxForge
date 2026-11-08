#!/usr/bin/env bash
# ProxForge — Création automatisée d'une VM Kali Linux Cloud-Init
set -euo pipefail

# ============================================================================
# VALIDATIONS
# ============================================================================

[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in curl qm pvesh awk tar; do command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }; done
command -v xz >/dev/null 2>&1 || command -v unxz >/dev/null 2>&1 || apt-get install -y -qq xz-utils >/dev/null 2>&1

# ============================================================================
# CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-kali-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
KALI_USER="${KALI_USER:-kali}"

# ============================================================================
# CACHE ET NETTOYAGE
# ============================================================================

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_CACHE_DIR"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/kali-linux-cloud-amd64.{tar.xz,raw,qcow2}.tmp 2>/dev/null || true
  (( exit_code != 0 )) && (( VM_CREATED )) && {
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT ERR

# ============================================================================
# TÉLÉCHARGEMENT
# ============================================================================

KALI_MIRROR="https://kali.download/cloud-images/"
LATEST_VERSION_DIR=$(curl -fsSL "$KALI_MIRROR" | grep -oP 'href="\Kkali-\d{4}\.\d+' | sort -V | tail -1)
[[ -z "$LATEST_VERSION_DIR" ]] && { echo -e "\e[31m[ERREUR]\e[0m Impossible de détecter la version Kali." >&2; exit 1; }

IMAGE_URL="${KALI_MIRROR}kali-${LATEST_VERSION_DIR}/kali-linux-${LATEST_VERSION_DIR}-cloud-genericcloud-amd64.tar.xz"
CACHE_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.tar.xz"
RAW_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.raw"
QCOW2_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.qcow2"

if [[ ! -f "$QCOW2_FILE" ]]; then
  [[ ! -f "$CACHE_FILE" ]] && {
    curl -fL --progress-bar -o "${CACHE_FILE}.tmp" "$IMAGE_URL" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
  }
  [[ ! -f "$RAW_FILE" ]] && {
    tar -xf "$CACHE_FILE" -C "$LOCAL_CACHE_DIR" --wildcards "*.raw" 2>/dev/null
    EXTRACTED_RAW=$(ls "${LOCAL_CACHE_DIR}"/*.raw 2>/dev/null | head -n 1)
    [[ -n "$EXTRACTED_RAW" ]] && mv "$EXTRACTED_RAW" "$RAW_FILE"
  }
  qemu-img convert -f raw -O qcow2 "$RAW_FILE" "${QCOW2_FILE}.tmp" 2>/dev/null && mv "${QCOW2_FILE}.tmp" "$QCOW2_FILE"
  rm -f "$CACHE_FILE" "$RAW_FILE"
fi

# ============================================================================
# CRÉATION VM
# ============================================================================

qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci --description "Kali Linux - ProxForge"
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"
qm importdisk "$VMID" "$QCOW2_FILE" "$STORAGE" --format qcow2 >/dev/null 2>&1

DISK_VOL=$(qm config "$VMID" | awk '/^unused0:/ {sub(/^unused0:[[:space:]]*/, ""); print; exit}')
[[ -z "$DISK_VOL" ]] && { echo -e "\e[31m[ERREUR]\e[0m Disque introuvable." >&2; exit 1; }

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket \
  --ciuser "$KALI_USER" --ipconfig0 ip=dhcp
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null 2>&1 || true

echo -e "\e[33m[IMPORTANT]\e[0m Configurez un mot de passe/SSH via Cloud-Init avant de démarrer !"
[[ "$START_VM" == "yes" ]] && qm start "$VMID" || true
echo -e "\n\e[32m[SUCCÈS]\e[0m VM Kali Linux créée (ID: $VMID) !"
