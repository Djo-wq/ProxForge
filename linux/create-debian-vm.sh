#!/usr/bin/env bash
# Script de création automatisée VM Debian Cloud-Init (Proxmox VE 9.2)
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-debian-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"

# Validation DISK_SIZE
if [[ ! "$DISK_SIZE" =~ ^[0-9]+[GgMm]?$ && ! "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
  echo -e "\e[31m[ERREUR]\e[0m DISK_SIZE doit être au format '8G', '50M' ou '100' (Go)."
  exit 1
fi

case "$DEBIAN_VERSION" in
  13) DEBIAN_CODENAME="trixie" ;;
  12) DEBIAN_CODENAME="bookworm" ;;
  11) DEBIAN_CODENAME="bullseye" ;;
  *) echo -e "\e[31m[ERREUR]\e[0m Version Debian non supportée. Utilisez 11, 12 ou 13."; exit 1 ;;
esac

ARCH=$(uname -m)
DEBIAN_ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && DEBIAN_ARCH="arm64"

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/debian-*.tmp 2>/dev/null || true
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression de la VM $VMID..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m Création VM Debian $DEBIAN_VERSION (ID: $VMID)..."

# --- TÉLÉCHARGEMENT ---
# URL mise à jour pour Debian 13 (Trixie)
URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VERSION}-genericcloud-${DEBIAN_ARCH}.qcow2"
WORK_FILE="${LOCAL_CACHE_DIR}/debian-${DEBIAN_VERSION}-cloud.qcow2"

if [[ ! -f "$WORK_FILE" ]]; then
  echo -e "\e[34m[INFO]\e[0m Téléchargement Debian ${DEBIAN_VERSION}..."
  if ! curl -L --progress-bar -o "${WORK_FILE}.tmp" "$URL"; then
    rm -f "${WORK_FILE}.tmp"
    echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement : $URL"
    exit 1
  fi
  mv "${WORK_FILE}.tmp" "$WORK_FILE"
else
  echo -e "\e[32m[OK]\e[0m Image Debian déjà en cache."
fi

# --- CRÉATION VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM..."
qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Import du disque..."
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2

DISK_VOL=$(qm config "$VMID" | awk -F: '/^unused0:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
if [[ -z "$DISK_VOL" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de récupérer le volume disque."
  exit 1
fi

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- DÉMARRAGE ---
if [[ "$START_VM" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Debian $DEBIAN_VERSION créée (ID: $VMID) !"
