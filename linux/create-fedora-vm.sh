#!/usr/bin/env bash
# Script de création automatisée VM Fedora Cloud-Init (Optimisé)
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-fedora-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# --- SÉCURITÉ NETTOYAGE ---
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Fedora (ID: $VMID)..."

# --- RÉCUPÉRATION DE L'URL ---
MIRROR="https://dl.fedoraproject.org/pub/fedora/linux/releases"
FEDORA_RELEASE=$(curl -fsSL "$MIRROR/" | grep -oP 'href="\K[0-9]+(?=/")' | sort -rn | head -1)
[[ -z "$FEDORA_RELEASE" ]] && FEDORA_RELEASE="41"

ARCH=$(uname -m)
IMAGE_DIR="${MIRROR}/${FEDORA_RELEASE}/Cloud/${ARCH}/images"
FILE=$(curl -fsSL "${IMAGE_DIR}/" | grep -oP 'href="\KFedora-Cloud-Base-Generic-[^"]+\.'"${ARCH}"'\.qcow2(?=")' | sort -V | tail -1)

if [[ -z "$FILE" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver l'image Fedora Cloud."
  exit 1
fi

URL="${IMAGE_DIR}/${FILE}"
WORK_FILE="${LOCAL_CACHE_DIR}/fedora-${FEDORA_RELEASE}-cloud.qcow2"

# --- TÉLÉCHARGEMENT ATOMIQUE ---
if [ -f "$WORK_FILE" ]; then
  echo -e "\e[32m[OK]\e[0m Image déjà présente localement : $WORK_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement de Fedora ${FEDORA_RELEASE} vers le cache..."
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
echo -e "\n\e[32m[SUCCÈS]\e[0m VM Fedora créée avec succès (ID: $VMID) !"
