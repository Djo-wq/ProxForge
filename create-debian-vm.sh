#!/usr/bin/env bash
# Script autonome de création de VM Debian Cloud-Init pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-debian-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# Choix de la version (12 = Bookworm, 13 = Trixie)
DEBIAN_VERSION="${DEBIAN_VERSION:-12}"

case "$DEBIAN_VERSION" in
  13) DEBIAN_CODENAME="trixie" ;;
  12) DEBIAN_CODENAME="bookworm" ;;
  11) DEBIAN_CODENAME="bullseye" ;;
  *)
    echo -e "\e[31m[ERREUR]\e[0m Version de Debian non supportée : '$DEBIAN_VERSION'"
    exit 1
    ;;
esac

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && DEBIAN_ARCH="amd64" || DEBIAN_ARCH="arm64"

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Debian $DEBIAN_VERSION ($DEBIAN_CODENAME) - ID: $VMID"

# --- 2. MISE EN CACHE LOCALE DE L'IMAGE CLOUD ---
URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VERSION}-genericcloud-${DEBIAN_ARCH}.qcow2"
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
WORK_FILE="${LOCAL_CACHE_DIR}/debian-${DEBIAN_VERSION}-cloud.qcow2"

if [ -f "$WORK_FILE" ]; then
  echo -e "\e[32m[OK]\e[0m Image déjà présente localement : $WORK_FILE"
  echo -e "\e[34m[INFO]\e[0m Téléchargement ignoré."
else
  echo -e "\e[34m[INFO]\e[0m L'image n'est pas présente localement."
  echo -e "\e[34m[INFO]\e[0m Téléchargement de Debian $DEBIAN_VERSION vers le cache..."
  curl -L --progress-bar -o "$WORK_FILE" "$URL"
fi

# --- 3. CRÉATION DE LA VM (QM) ---
echo -e "\e[34m[INFO]\e[0m Création de la VM avec BIOS UEFI (ovmf) et machine q35..."
qm create "$VMID" \
  --name "$HN" \
  --agent 1 \
  --bios ovmf \
  --machine q35 \
  --cpu host \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 \
  --onboot 1 \
  --scsihw virtio-scsi-pci

# Création du disque EFI
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

# --- 4. IMPORTATION ET CONFIGURATION DES DISQUES ---
echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel (Veuillez patienter)..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2)

# Récupération dynamique du nom du volume généré par Proxmox
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

echo -e "\e[34m[INFO]\e[0m Attachement du disque principal et Cloud-Init..."
qm set "$VMID" \
  --scsi0 "${DISK_VOL},discard=on,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket

qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- 5. DÉMARRAGE DE LA VM ---
if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM Debian..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Debian $DEBIAN_VERSION créée avec succès (ID: $VMID) !"
