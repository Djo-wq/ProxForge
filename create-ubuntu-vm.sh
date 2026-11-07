#!/usr/bin/env bash

# Stop execution on error
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT (Modifiable selon vos besoins) ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-ubuntu-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"       # Augmenté à 20G (7G est très juste pour un usage système)
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# Version d'Ubuntu (ex: 26.04, 24.04, 22.04)
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

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) - ID: $VMID"

# --- 2. TÉLÉCHARGEMENT DE L'IMAGE CLOUD UBUNTU ---
URL="https://cloud-images.ubuntu.com/releases/server/${UBUNTU_CODENAME}/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-${UBUNTU_ARCH}.img"
TEMP_DIR=$(mktemp -d)
WORK_FILE="${TEMP_DIR}/ubuntu-${UBUNTU_VERSION}.img"

echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image officielle Ubuntu Cloud..."
echo -e "\e[33m[URL]\e[0m $URL"
curl -L --progress-bar -o "$WORK_FILE" "$URL"

# --- 3. CRÉATION DE LA VM DANS PROXMOX (QM) ---
echo -e "\e[34m[INFO]\e[0m Création de la VM avec BIOS UEFI (ovmf) et machine q35..."
qm create "$VMID" \
  --name "$HN" \
  --agent enabled=1 \
  --bios ovmf \
  --machine q35 \
  --cpu host \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 \
  --onboot 1 \
  --scsihw virtio-scsi-pci

# --- 4. CONFIGURATION DISQUES ET CLOUD-INIT ---
echo -e "\e[34m[INFO]\e[0m Configuration du stockage EFI et importation du disque..."

# Disque EFI obligatoire pour le boot UEFI (OVMF)
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

# Importation du disque cloud dans le stockage Proxmox
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format raw 1>/dev/null

# Attachement du disque principal et création du lecteur Cloud-Init
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket

# Redimensionnement du disque principal à la taille définie
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- 5. NETTOYAGE ET DÉMARRAGE ---
rm -rf "$TEMP_DIR"

if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM Ubuntu..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m La VM Ubuntu $UBUNTU_VERSION a été créée avec succès !"
echo -e " - ID : $VMID"
echo -e " - Nom : $HN"
echo -e " - Version OS : Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
echo -e " - RAM : ${RAM_SIZE} MB | CPU : ${CPU_CORES} cœurs"
echo -e " - Disque : ${DISK_SIZE} sur le stockage '${STORAGE}'"
