#!/usr/bin/env bash
# ProxForge — Création d'une VM Fedora Cloud-Init
set -euo pipefail

# ============================================================================
# VALIDATIONS
# ============================================================================

[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in curl qm pvesh awk; do command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }; done

# ============================================================================
# CONFIGURATION
# ============================================================================

HN="${HN:-fedora-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
VMID="${VMID:-$(pvesh get /cluster/nextid 2>/dev/null || echo \"1000\")}"
CIUSER="${CIUSER:-admin}"
CIPASSWORD="${CIPASSWORD:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"

[[ -n "$SSH_PUBKEY_FILE" && ! -f "$SSH_PUBKEY_FILE" ]] && { echo -e "\e[31m[ERREUR]\e[0m Clé SSH introuvable." >&2; exit 1; }
[[ -z "$CIPASSWORD" && -z "$SSH_PUBKEY_FILE" ]] && echo -e "\e[33m[AVERTISSEMENT]\e[0m Configurez Cloud-Init pour $CIUSER." >&2

# ============================================================================
# CACHE ET NETTOYAGE
# ============================================================================

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_CACHE_DIR"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/fedora-*.qcow2.tmp 2>/dev/null || true
  (( exit_code != 0 )) && (( VM_CREATED )) && {
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT ERR

# ============================================================================
# DÉTECTION VERSION FEDORA
# ============================================================================

MIRROR="https://dl.fedoraproject.org/pub/fedora/linux/releases"
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && FEDORA_ARCH="x86_64" || FEDORA_ARCH="aarch64"

FEDORA_RELEASE=$(curl -fsSL "${MIRROR}/" 2>/dev/null | grep -oP 'href="\K[0-9]+(?=/")' | sort -rn | head -n 1 || echo "43")
IMAGE_DIR="${MIRROR}/${FEDORA_RELEASE}/Cloud/${FEDORA_ARCH}/images"
FILE=$(curl -fsSL "${IMAGE_DIR}/" 2>/dev/null | grep -oP 'href="\KFedora-Cloud-Base-Generic-[^"]+\.'"${FEDORA_ARCH}\"'\.qcow2(?=\")' | sort -V | tail -n 1)
[[ -z "$FILE" ]] && { echo -e "\e[31m[ERREUR]\e[0m Image Fedora introuvable." >&2; exit 1; }

URL="${IMAGE_DIR}/${FILE}"
WORK_FILE="${LOCAL_CACHE_DIR}/fedora-${FEDORA_RELEASE}-cloud-${FEDORA_ARCH}.qcow2"
[[ -f "$WORK_FILE" ]] || { curl -fL --progress-bar -o "${WORK_FILE}.tmp" "$URL" && mv "${WORK_FILE}.tmp" "$WORK_FILE"; }

# ============================================================================
# CRÉATION VM
# ============================================================================

qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci --description "Fedora ${FEDORA_RELEASE} - ProxForge"
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2 >/dev/null 2>&1

DISK_VOL=$(qm config "$VMID" | awk '/^unused0:/ {sub(/^unused0:[[:space:]]*/, ""); print; exit}')
[[ -z "$DISK_VOL" ]] && { echo -e "\e[31m[ERREUR]\e[0m Disque introuvable." >&2; exit 1; }

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null 2>&1 || true

# ============================================================================
# CLOUD-INIT
# ============================================================================

CI_ARGS=(--ciuser "$CIUSER" --ipconfig0 "$IPCONFIG0")
[[ -n "$SSH_PUBKEY_FILE" ]] && CI_ARGS+=(--sshkeys "$SSH_PUBKEY_FILE")
[[ -n "$CIPASSWORD" ]] && CI_ARGS+=(--cipassword "$CIPASSWORD")
qm set "$VMID" "${CI_ARGS[@]}"

[[ "$START_VM" == "yes" ]] && qm start "$VMID" || true
echo -e "\n\e[32m[SUCCÈS]\e[0m VM Fedora ${FEDORA_RELEASE} créée (ID: $VMID) !"
[[ -n "$SSH_PUBKEY_FILE" ]] && echo -e "\e[36m[INFO]\e[0m Connexion: ssh ${CIUSER}@<IP_VM>"
