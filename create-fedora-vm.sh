#!/usr/bin/env bash
set -euo pipefail

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

MIRROR="https://dl.fedoraproject.org/pub/fedora/linux/releases"
FEDORA_RELEASE=$(curl -fsSL "$MIRROR/" 2>/dev/null | grep -oP 'href="\K[0-9]+(?=/")' | sort -rn | head -1)
[[ -z "$FEDORA_RELEASE" ]] && FEDORA_RELEASE="41"

ARCH=$(uname -m)
IMAGE_DIR="${MIRROR}/${FEDORA_RELEASE}/Cloud/${ARCH}/images"
FILE=$(curl -fsSL "${IMAGE_DIR}/" 2>/dev/null | grep -oP 'href="\KFedora-Cloud-Base-Generic-[^"]+\.'"${ARCH}"'\.qcow2(?=")' | sort -V | tail -1)

if [[ -z "$FILE" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver l'image Fedora Cloud."
  exit 1
fi

URL="${IMAGE_DIR}/${FILE}"
TEMP_DIR=$(mktemp -d)
WORK_FILE="${TEMP_DIR}/${FILE}"

echo -e "\e[34m[INFO]\e[0m Téléchargement de Fedora ${FEDORA_RELEASE}..."
curl -L --progress-bar -o "$WORK_FILE" "$URL"

# Fix : syntaxe --agent 1
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

echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel (Veuillez patienter)..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format raw)

# Fix : Récupération dynamique du nom du volume importé
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

qm set "$VMID" \
  --scsi0 "${DISK_VOL},discard=on,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket

qm resize "$VMID" scsi0 "$DISK_SIZE"

rm -rf "$TEMP_DIR"

if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Fedora créée avec succès (ID: $VMID) !"
