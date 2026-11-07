#!/usr/bin/env bash

# Exit on error
set -euo pipefail

# --- 1. CONFIGURATION DE BASE (Ajustable selon vos besoins) ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-fedora-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Fedora (ID: $VMID)..."

# --- 2. DÉTECTION ET TÉLÉCHARGEMENT DE LA DERNIÈRE IMAGE FEDORA CLOUD ---
echo -e "\e[34m[INFO]\e[0m Recherche de la dernière version de Fedora Cloud..."

MIRROR="https://dl.fedoraproject.org/pub/fedora/linux/releases"
# Récupère le numéro de la dernière release stable
FEDORA_RELEASE=$(curl -fsSL "$MIRROR/" 2>/dev/null | grep -oP 'href="\K[0-9]+(?=/")' | sort -rn | head -1)
[[ -z "$FEDORA_RELEASE" ]] && FEDORA_RELEASE="41"

ARCH=$(uname -m)
IMAGE_DIR="${MIRROR}/${FEDORA_RELEASE}/Cloud/${ARCH}/images"

# Récupère le nom du dernier fichier image qcow2
FILE=$(curl -fsSL "${IMAGE_DIR}/" 2>/dev/null | grep -oP 'href="\KFedora-Cloud-Base-Generic-[^"]+\.'"${ARCH}"'\.qcow2(?=")' | sort -V | tail -1)

if [[ -z "$FILE" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver l'image Fedora Cloud sur le miroir."
  exit 1
fi

URL="${IMAGE_DIR}/${FILE}"
TEMP_DIR=$(mktemp -d)
WORK_FILE="${TEMP_DIR}/${FILE}"

echo -e "\e[32m[OK]\e[0m Image trouvée : Fedora ${FEDORA_RELEASE} (${FILE})"
echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image..."
curl -L --progress-bar -o "$WORK_FILE" "$URL"

# --- 3. CRÉATION DE LA VM SUR PROXMOX (QM) ---
echo -e "\e[34m[INFO]\e[0m Création de la structure de la VM $VMID..."

# Création de la VM avec BIOS UEFI (ovmf), agent Proxmox activé et type q35
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

# --- 4. CONFIGURATION DES DISQUES & CLOUD-INIT ---
echo -e "\e[34m[INFO]\e[0m Configuration du stockage UEFI et Cloud-Init..."

# Allocation du disque EFI obligatoire pour OVMF
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

# Importation du disque cloud Fedora dans Proxmox
echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel..."
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format raw 1>/dev/null

# Attachement du disque importé et activation du lecteur Cloud-Init
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket

# Redimensionnement du disque principal à la taille demandée
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- 5. NETTOYAGE ET DÉMARRAGE ---
rm -rf "$TEMP_DIR"

if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM Fedora..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m La VM Fedora $FEDORA_RELEASE a été créée avec succès !"
echo -e " - ID : $VMID"
echo -e " - Nom : $HN"
echo -e " - RAM : ${RAM_SIZE} MB | CPU : ${CPU_CORES} cœurs"
echo -e " - Disque : ${DISK_SIZE} sur ${STORAGE}"
