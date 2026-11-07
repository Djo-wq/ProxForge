#!/usr/bin/env bash
# Script de création automatisée VM Ubuntu Cloud-Init (Optimisé)
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-ubuntu-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"

case "$UBUNTU_VERSION" in
  26.04) UBUNTU_CODENAME="resolute" ;;
  24.04) UBUNTU_CODENAME="noble" ;;
  22.04) UBUNTU_CODENAME="jammy" ;;
  *) echo -e "\e[31m[ERREUR]\e[0m Version d'Ubuntu non supportée."; exit 1 ;;
esac

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && UBUNTU_ARCH="amd64" || UBUNTU_ARCH="arm64"

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Ubuntu $UBUNTU_VERSION (ID: $VMID)..."

# --- TÉLÉCHARGEMENT ATOMIQUE ---
URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-${UBUNTU_ARCH}.img"
WORK_FILE="${LOCAL_CACHE_DIR}/ubuntu-${UBUNTU_VERSION}-cloud.img"

if [ -f "$WORK_FILE" ]; then
  echo -e "\e[32m[OK]\e[0m Image déjà présente localement : $WORK_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement d'Ubuntu vers le cache..."
  curl -fL --progress-bar -o "${WORK_FILE}.tmp" "$URL"
  mv "${WORK_FILE}.tmp" "$WORK_FILE"
fi

# --- CRÉATION DE LA VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM..."
qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2)
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

# FIX : cache=writeback ajouté
qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE"

if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi
echo -e "\n\e[32m[SUCCÈS]\e[0m VM Ubuntu créée avec succès (ID: $VMID) !"
