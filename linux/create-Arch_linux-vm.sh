#!/usr/bin/env bash
# Script de création automatisée d'une VM Arch Linux pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-arch-linux-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20}" # En Go (ex: 20 pour 20G)
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# --- 2. GESTION DU TÉLÉCHARGEMENT DE L'IMAGE ARCH LINUX ---
LOCAL_ISO_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_ISO_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Arch Linux (ID: $VMID)..."

# URL de la dernière image ISO Arch Linux
URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
ISO_FILE="archlinux-latest-x86_64.iso"
CACHE_FILE="${LOCAL_ISO_DIR}/${ISO_FILE}"
ISO_VOLUME="local:iso/${ISO_FILE}"

if [ ! -f "$CACHE_FILE" ]; then
    echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image ISO Arch Linux vers le cache..."
    curl -fL --progress-bar -o "${CACHE_FILE}.tmp" "$URL"
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
else
    echo -e "\e[32m[OK]\e[0m Image ISO Arch Linux déjà présente localement : $CACHE_FILE"
fi

# --- 3. CRÉATION DE LA VM (QM) ---
echo -e "\e[34m[INFO]\e[0m Création de la VM (Machine q35, BIOS UEFI)..."
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

# --- 4. CRÉATION DU DISQUE ET ATTACHEMENT DU LECTEUR CD ---
echo -e "\e[34m[INFO]\e[0m Création du disque dur de ${DISK_SIZE} Go..."
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1,cache=writeback"

echo -e "\e[34m[INFO]\e[0m Insertion de l'ISO Arch Linux..."
qm set "$VMID" --ide2 "$ISO_VOLUME,media=cdrom"

# Ordre de démarrage : le disque d'abord, puis le CD.
# Le disque étant vide, le système bootera sur le CD. Une fois installé, il bootera sur le disque.
qm set "$VMID" --boot "order=scsi0;ide2"

# --- 5. DÉMARRAGE ---
if [ "$START_VM" == "yes" ]; then
    echo -e "\e[34m[INFO]\e[0m Démarrage de la VM Arch Linux..."
    qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Arch Linux préparée avec succès (ID: $VMID) !"
echo -e "\e[33m====================================================\e[0m"
echo -e "\e[33m 1. Ouvrez la console de la VM dans Proxmox.\e[0m"
echo -e "\e[33m 2. L'ISO Live se connecte automatiquement en root.\e[0m"
echo -e "\e[33m 3. Lancez la commande 'archinstall' pour commencer l'installation sur /dev/sda.\e[0m"
echo -e "\e[33m 4. Pensez à installer 'qemu-guest-agent' dans le système invité.\e[0m"
echo -e "\e[33m 5. Une fois installé, vous pouvez retirer l'ISO (qm set $VMID --ide2 none).\e[0m"
echo -e "\e[33m====================================================\e[0m"
