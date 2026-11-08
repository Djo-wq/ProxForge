#!/usr/bin/env bash
# Script de création automatisée d'une VM Kali Linux (Cloud-Init) pour Proxmox VE 9.2
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-kali-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
KALI_USER="${KALI_USER:-kali}"

# Validation DISK_SIZE
if [[ ! "$DISK_SIZE" =~ ^[0-9]+[GgMm]?$ && ! "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
  echo -e "\e[31m[ERREUR]\e[0m DISK_SIZE doit être au format '20G', '50M' ou '100' (Go)."
  exit 1
fi

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/kali-*.tmp "${LOCAL_CACHE_DIR}"/kali-*.tar.xz "${LOCAL_CACHE_DIR}"/kali-*.raw 2>/dev/null || true
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression de la VM $VMID..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m Création VM Kali Linux (ID: $VMID)..."

# --- TÉLÉCHARGEMENT ---
KALI_MIRROR="https://kali.download/cloud-images/"
CACHE_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.tar.xz"
QCOW2_FILE="${LOCAL_CACHE_DIR}/kali-linux-cloud-amd64.qcow2"

# Méthode robuste pour trouver la dernière version
LATEST_VERSION_DIR=$(curl -fsSL "$KALI_MIRROR" | grep -oP 'href="kali-\d{4}\.\d+/"' | sort -Vr | head -1 | sed -n 's/.*kali-\([0-9.]\+\)\/.*/\1/p')

if [[ -z "$LATEST_VERSION_DIR" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver la dernière version Kali."
  exit 1
fi

IMAGE_URL="${KALI_MIRROR}${LATEST_VERSION_DIR}/kali-linux-${LATEST_VERSION_DIR#kali-}-cloud-genericcloud-amd64.tar.xz"

if [[ ! -f "$QCOW2_FILE" ]]; then
  if [[ ! -f "$CACHE_FILE" ]]; then
    echo -e "\e[34m[INFO]\e[0m Téléchargement Kali Linux ($LATEST_VERSION_DIR)..."
    if ! curl -L --progress-bar -o "${CACHE_FILE}.tmp" "$IMAGE_URL"; then
      rm -f "${CACHE_FILE}.tmp"
      echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement : $IMAGE_URL"
      exit 1
    fi
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
  fi

  echo -e "\e[34m[INFO]\e[0m Extraction et conversion de l'image..."
  if ! tar -xf "$CACHE_FILE" -C "$LOCAL_CACHE_DIR" --wildcards "*.raw" 2>/dev/null; then
    echo -e "\e[31m[ERREUR]\e[0m Échec de l'extraction. Vérifiez que 'tar' est installé."
    exit 1
  fi

  EXTRACTED_RAW=$(ls "${LOCAL_CACHE_DIR}"/kali-linux-*-cloud-genericcloud-amd64.raw 2>/dev/null | head -1)
  if [[ -z "$EXTRACTED_RAW" ]]; then
    EXTRACTED_RAW=$(ls "${LOCAL_CACHE_DIR}"/*.raw 2>/dev/null | head -1)
  fi

  if [[ -z "$EXTRACTED_RAW" ]]; then
    echo -e "\e[31m[ERREUR]\e[0m Aucun fichier .raw trouvé dans l'archive."
    exit 1
  fi

  if ! qemu-img convert -f raw -O qcow2 "$EXTRACTED_RAW" "${QCOW2_FILE}.tmp"; then
    echo -e "\e[31m[ERREUR]\e[0m Échec de la conversion raw→qcow2. Vérifiez que 'qemu-img' est installé."
    rm -f "${QCOW2_FILE}.tmp"
    exit 1
  fi
  mv "${QCOW2_FILE}.tmp" "$QCOW2_FILE"
  rm -f "$EXTRACTED_RAW"
else
  echo -e "\e[32m[OK]\e[0m Image Kali déjà en cache."
fi

# --- CRÉATION VM ---
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
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Import du disque..."
qm importdisk "$VMID" "$QCOW2_FILE" "$STORAGE" --format qcow2

DISK_VOL=$(qm config "$VMID" | awk -F: '/^unused0:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
if [[ -z "$DISK_VOL" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de récupérer le volume disque."
  exit 1
fi

qm set "$VMID" \
  --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- CLOUD-INIT ---
qm set "$VMID" \
  --ciuser "$KALI_USER" \
  --ipconfig0 ip=dhcp

echo -e "\n\e[33m[IMPORTANT]\e[0m Utilisateur Cloud-Init : '$KALI_USER'"
echo -e "\e[33m[IMPORTANT]\e[0m Configurez un mot de passe ou une clé SSH via l'interface Proxmox avant de démarrer."

# --- DÉMARRAGE ---
if [[ "$START_VM" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Kali Linux créée (ID: $VMID) !"
