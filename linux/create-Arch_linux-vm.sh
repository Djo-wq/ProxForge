#!/usr/bin/env bash
# ProxForge — Création d'une VM Arch Linux (installation manuelle)
set -euo pipefail

# ============================================================================
# VALIDATIONS
# ============================================================================

[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in curl qm pvesh; do command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }; done

# ============================================================================
# CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-arch-linux-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# ============================================================================
# CACHE ET NETTOYAGE
# ============================================================================

LOCAL_ISO_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_ISO_DIR"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_ISO_DIR}"/archlinux-*.iso.tmp 2>/dev/null || true
  (( exit_code != 0 )) && (( VM_CREATED )) && {
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT ERR

# ============================================================================
# TÉLÉCHARGEMENT ISO
# ============================================================================

URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
ISO_FILE="archlinux-latest-x86_64.iso"
CACHE_FILE="${LOCAL_ISO_DIR}/${ISO_FILE}"
ISO_VOLUME="${STORAGE}:iso/${ISO_FILE}"

[[ ! -f "$CACHE_FILE" ]] && {
  curl -fL --progress-bar -o "${CACHE_FILE}.tmp" "$URL" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
}

# ============================================================================
# CRÉATION VM
# ============================================================================

qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci --description "Arch Linux - ProxForge"
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1,cache=writeback"
qm set "$VMID" --ide2 "$ISO_VOLUME,media=cdrom"
qm set "$VMID" --boot "order=ide2;scsi0"

[[ "$START_VM" == "yes" ]] && qm start "$VMID" || true

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Arch Linux prête (ID: $VMID) !"
echo -e "\e[36m[INFO]\e[0m 1. Ouvrez la console dans Proxmox"
echo -e "\e[36m[INFO]\e[0m 2. Lancez: archinstall"
echo -e "\e[36m[INFO]\e[0m 3. Installez sur /dev/sda"
echo -e "\e[36m[INFO]\e[0m 4. Retirez l'ISO après installation: qm set $VMID --ide2 none"
