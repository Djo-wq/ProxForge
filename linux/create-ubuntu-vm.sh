#!/usr/bin/env bash
# ProxForge — Création automatisée d'une VM Ubuntu Cloud-Init (Optimisé pour Proxmox VE 9.2)
set -euo pipefail

# ============================================================================
# 1. VALIDATIONS PRÉCOCES
# ============================================================================

if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Ce script doit être exécuté en tant que root." >&2
  exit 1
fi

for cmd in curl qm pvesh awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "\e[31m[ERREUR]\e[0m La commande '$cmd' est requise mais introuvable." >&2
    exit 1
  fi
done

# ============================================================================
# 2. CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-ubuntu-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) UBUNTU_ARCH="amd64" ;;
  aarch64) UBUNTU_ARCH="arm64" ;;
  *) echo -e "\e[31m[ERREUR]\e[0m Architecture '$ARCH' non supportée." >&2; exit 1 ;;
esac

case "$UBUNTU_VERSION" in
  24.04) UBUNTU_CODENAME="noble" ;;
  22.04) UBUNTU_CODENAME="jammy" ;;
  20.04) UBUNTU_CODENAME="focal" ;;
  18.04) UBUNTU_CODENAME="bionic" ;;
  *) echo -e "\e[31m[ERREUR]\e[0m Version Ubuntu '$UBUNTU_VERSION' non supportée." >&2; exit 1 ;;
esac

# ============================================================================
# 3. CACHE ET NETTOYAGE
# ============================================================================

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_CACHE_DIR"

VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/*.tmp 2>/dev/null || true
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT ERR

# ============================================================================
# 4. TÉLÉCHARGEMENT
# ============================================================================

WORK_FILE="${LOCAL_CACHE_DIR}/ubuntu-${UBUNTU_VERSION}-cloud-${UBUNTU_ARCH}.img"
URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-${UBUNTU_ARCH}.img"

if [[ -f "$WORK_FILE" ]]; then
  echo -e "\e[32m[OK]\e[0m Image Ubuntu déjà présente: $WORK_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image Ubuntu ${UBUNTU_VERSION}..."
  if ! curl -fL --progress-bar -o "${WORK_FILE}.tmp" "$URL"; then
    echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement." >&2; exit 1
  fi
  mv "${WORK_FILE}.tmp" "$WORK_FILE"
fi

# ============================================================================
# 5. CRÉATION VM
# ============================================================================

echo -e "\e[34m[INFO]\e[0m Création de la VM (ID: $VMID)..."
qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci --description "Ubuntu ${UBUNTU_VERSION} - ProxForge"

VM_CREATED=1
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Importation du disque..."
if ! qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2 >/dev/null 2>&1; then
  echo -e "\e[31m[ERREUR]\e[0m Échec de l'importation." >&2; exit 1
fi

DISK_VOL=$(qm config "$VMID" | awk '/^unused0:/ {sub(/^unused0:[[:space:]]*/, ""); print; exit}')
[[ -z "$DISK_VOL" ]] && { echo -e "\e[31m[ERREUR]\e[0m Disque introuvable." >&2; exit 1; }

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null 2>&1 || true

if [[ "$START_VM" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID" || echo -e "\e[33m[AVERTISSEMENT]\e[0m Échec du démarrage." >&2
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Ubuntu ${UBUNTU_VERSION} créée (ID: $VMID) !"
