#!/usr/bin/env bash
set -euo pipefail

VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-ubuntu-vm}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-30G}"
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

# Fix : Utilisation du dossier /current/ qui est toujours stable et maintenu par Canonical
URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-${UBUNTU_ARCH}.img"
TEMP_DIR=$(mktemp -d)
WORK_FILE="${TEMP_DIR}/ubuntu-${UBUNTU_VERSION}.img"

echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image officielle Ubuntu Cloud..."
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

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Ubuntu créée avec succès (ID: $VMID) !"
