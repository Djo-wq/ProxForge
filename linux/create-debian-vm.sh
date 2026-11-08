#!/usr/bin/env bash
# ProxForge — Création automatisée d'une VM Debian Cloud-Init
set -euo pipefail

# ============================================================================
# VALIDATIONS
# ============================================================================

[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in curl qm pvesh awk; do command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }; done

# ============================================================================
# CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-debian-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && DEBIAN_ARCH="amd64" || DEBIAN_ARCH="arm64"

case "$DEBIAN_VERSION" in
  13) DEBIAN_CODENAME="trixie" ;;
  12) DEBIAN_CODENAME="bookworm" ;;
  11) DEBIAN_CODENAME="bullseye" ;;
  10) DEBIAN_CODENAME="buster" ;;
  *) echo -e "\e[31m[ERREUR]\e[0m Version Debian non supportée." >&2; exit 1 ;;
esac

# ============================================================================
# CACHE ET NETTOYAGE
# ============================================================================

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_CACHE_DIR"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/*.tmp 2>/dev/null || true
  (( exit_code != 0 )) && (( VM_CREATED )) && {
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT ERR

# ============================================================================
# TÉLÉCHARGEMENT
# ============================================================================

WORK_FILE="${LOCAL_CACHE_DIR}/debian-${DEBIAN_VERSION}-cloud-${DEBIAN_ARCH}.qcow2"
URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VERSION}-genericcloud-${DEBIAN_ARCH}.qcow2"

[[ -f "$WORK_FILE" ]] || {
  echo -e "\e[34m[INFO]\e[0m Téléchargement de Debian ${DEBIAN_VERSION}..."
  curl -fL --progress-bar -o "${WORK_FILE}.tmp" "$URL" && mv "${WORK_FILE}.tmp" "$WORK_FILE"
}

# ============================================================================
# CRÉATION VM
# ============================================================================

qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci --description "Debian ${DEBIAN_VERSION} - ProxForge"
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2 >/dev/null 2>&1

DISK_VOL=$(qm config "$VMID" | awk '/^unused0:/ {sub(/^unused0:[[:space:]]*/, ""); print; exit}')
[[ -z "$DISK_VOL" ]] && { echo -e "\e[31m[ERREUR]\e[0m Disque introuvable." >&2; exit 1; }

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null 2>&1 || true

[[ "$START_VM" == "yes" ]] && qm start "$VMID" || true
echo -e "\n\e[32m[SUCCÈS]\e[0m VM Debian ${DEBIAN_VERSION} créée (ID: $VMID) !"
