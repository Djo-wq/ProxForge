#!/usr/bin/env bash
# Script autonome de création de VM Ubuntu Cloud-Init pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION ---
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
  *)
    echo -e "\e[31m[ERREUR]\e[0m Version d'Ubuntu non supportée : '$UBUNTU_VERSION'"
    exit 1
    ;;
esac

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && UBUNTU_ARCH="amd64" || UBUNTU_ARCH="arm64"

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Ubuntu $UBUNTU_VERSION - ID: $VMID"

# --- 2. MISE EN CACHE LOCALE ---
URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-${UBUNTU_ARCH}.img"
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
WORK_FILE="${LOCAL_CACHE_DIR}/ubuntu-${UBUNTU_VERSION}-cloud.img"

if [ -f "$WORK_FILE" ]; then
  echo -e "\e[32m[OK]\e[0m Image déjà présente localement : $WORK_FILE"
  echo -e "\e[34m[INFO]\e[0m Téléchargement ignoré."
else
  echo -e "\e[34m[INFO]\e[0m L'image n'est pas présente localement."
  echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image officielle vers le cache..."
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

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

# --- 4. IMPORTATION ET CONFIGURATION DES DISQUES ---
echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel (Veuillez patienter)..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format raw)

# Récupération dynamique du nom du volume importé généré par Proxmox
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

echo -e "\e[34m[INFO]\e[0m Attachement du disque et configuration Cloud-Init..."
qm set "$VMID" \
  --scsi0 "${DISK_VOL},discard=on,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket

qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- 5. DÉMARRAGE ---
if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Ubuntu créée avec succès (ID: $VMID) !"
