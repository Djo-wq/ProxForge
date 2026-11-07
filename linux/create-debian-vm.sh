#!/usr/bin/env bash
# Script de création automatisée VM Debian Cloud-Init (Optimisé)
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-debian-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
DEBIAN_VERSION="${DEBIAN_VERSION:-12}"

case "$DEBIAN_VERSION" in
  13) DEBIAN_CODENAME="trixie" ;;
  12) DEBIAN_CODENAME="bookworm" ;;
  11) DEBIAN_CODENAME="bullseye" ;;
  *) echo -e "\e[31m[ERREUR]\e[0m Version Debian non supportée."; exit 1 ;;
esac

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && DEBIAN_ARCH="amd64" || DEBIAN_ARCH="arm64"

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Debian $DEBIAN_VERSION (ID: $VMID)..."

# --- TÉLÉCHARGEMENT ATOMIQUE ---
URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VERSION}-genericcloud-${DEBIAN_ARCH}.qcow2"
WORK_FILE="${LOCAL_CACHE_DIR}/debian-${DEBIAN_VERSION}-cloud.qcow2"

if [ -f "$WORK_FILE" ]; then
  echo -e "\e[32m[OK]\e[0m Image déjà présente localement : $WORK_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement de Debian vers le cache..."
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
echo -e "\n\e[32m[SUCCÈS]\e[0m VM Debian créée avec succès (ID: $VMID) !"
