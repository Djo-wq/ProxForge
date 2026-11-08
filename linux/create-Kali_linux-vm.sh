#!/usr/bin/env bash
# Script de création automatisée d'une VM Kali Linux (Cloud-Init) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-kali-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# Utilisateur par défaut de l'image Kali Cloud
KALI_USER="kali"

# --- 2. GESTION DU TÉLÉCHARGEMENT DE L'IMAGE KALI ---
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Kali Linux (ID: $VMID)..."

# Recherche de la dernière version Cloud Generic de Kali Linux
KALI_MIRROR="https://kali.download/cloud-images/"
# On cherche le dernier dossier de version (ex: kali-2024.1)
LATEST_VERSION_DIR=$(curl -fsSL "$KALI_MIRROR" | grep -oP 'href="kali-\d{4}\.\d+/"' | sort -V | tail -1 | grep -oP 'kali-\d{4}\.\d+')

if [[ -z "$LATEST_VERSION_DIR" ]]; then
    echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le dossier de la dernière version sur les miroirs Kali."
    exit 1
fi

# On cherche l'image genericcloud pour amd64 en .tar.xz
# Note: Kali distribue souvent l'image raw compressée plutôt que du qcow2 direct
IMAGE_URL="${KALI_MIRROR}${LATEST_VERSION_DIR}/kali-linux-${LATEST_VERSION_DIR#kali-}-cloud-genericcloud-amd64.tar.xz"
CACHE_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.tar.xz"
RAW_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.raw"
QCOW2_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.qcow2"

if [ ! -f "$QCOW2_FILE" ]; then
    if [ ! -f "$CACHE_FILE" ]; then
        echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image Kali Linux ($LATEST_VERSION_DIR)..."
        curl -fL --progress-bar -o "${CACHE_FILE}.tmp" "$IMAGE_URL"
        mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    fi

    if [ ! -f "$RAW_FILE" ]; then
        echo -e "\e[34m[INFO]\e[0m Extraction de l'image .tar.xz..."
        # Utilisation de tar pour extraire l'archive (nécessite xz-utils installé sur l'hôte)
        tar -xf "$CACHE_FILE" -C "$LOCAL_CACHE_DIR" --wildcards "*.raw" 
        # On renomme le fichier extrait (qui a souvent le nom complet de la release)
        EXTRACTED_RAW=$(ls ${LOCAL_CACHE_DIR}/*.raw | head -n 1)
        mv "$EXTRACTED_RAW" "$RAW_FILE"
    fi

    echo -e "\e[34m[INFO]\e[0m Conversion de l'image en qcow2..."
    qemu-img convert -f raw -O qcow2 "$RAW_FILE" "${QCOW2_FILE}.tmp"
    mv "${QCOW2_FILE}.tmp" "$QCOW2_FILE"
    
    # Nettoyage des fichiers intermédiaires
    rm -f "$CACHE_FILE" "$RAW_FILE"
else
    echo -e "\e[32m[OK]\e[0m Image Kali Linux déjà présente en cache : $QCOW2_FILE"
fi

# --- 3. CRÉATION DE LA VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM..."
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

echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$QCOW2_FILE" "$STORAGE" --format qcow2)
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

# Ajout du disque avec cache=writeback et du lecteur Cloud-Init
qm set "$VMID" \
    --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket

qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- 4. CONFIGURATION CLOUD-INIT DE BASE ---
# On configure un utilisateur par défaut et l'IP en DHCP
qm set "$VMID" \
    --ciuser "$KALI_USER" \
    --ipconfig0 ip=dhcp

echo -e "\n\e[33m[IMPORTANT]\e[0m Un utilisateur par défaut '$KALI_USER' a été configuré via Cloud-Init."
echo -e "\e[33m            \e[0m N'oubliez pas de configurer un mot de passe ou une clé SSH via l'interface Proxmox (Cloud-Init) avant de démarrer."

# --- 5. DÉMARRAGE ---
if [ "$START_VM" == "yes" ]; then
    echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
    qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Kali Linux créée avec succès (ID: $VMID) !"
