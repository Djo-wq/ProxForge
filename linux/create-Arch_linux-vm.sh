#!/usr/bin/env bash
# Script de création automatisée d'une VM Arch Linux pour Proxmox VE 9.2
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-arch-linux-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# Validation DISK_SIZE
if [[ ! "$DISK_SIZE" =~ ^[0-9]+[GgMm]$ ]]; then
  echo -e "\e[31m[ERREUR]\e[0m DISK_SIZE doit inclure une unité (ex: 20G, 50M)."
  exit 1
fi

LOCAL_ISO_DIR="/var/lib/vz/template/iso"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_ISO_DIR}"/archlinux-*.tmp 2>/dev/null || true
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression de la VM $VMID..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m Création VM Arch Linux (ID: $VMID)..."

# --- TÉLÉCHARGEMENT ---
URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
ISO_FILE="archlinux-latest-x86_64.iso"
CACHE_FILE="${LOCAL_ISO_DIR}/${ISO_FILE}"
ISO_VOLUME="${STORAGE}:iso/${ISO_FILE}"

if [[ ! -f "$CACHE_FILE" ]]; then
  echo -e "\e[34m[INFO]\e[0m Téléchargement Arch Linux ISO..."
  if ! curl -L --progress-bar -o "${CACHE_FILE}.tmp" "$URL"; then
    rm -f "${CACHE_FILE}.tmp"
    echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement : $URL"
    exit 1
  fi
  mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
else
  echo -e "\e[32m[OK]\e[0m ISO Arch Linux déjà en cache."
fi

# Vérifier que le fichier ISO est valide
if [[ ! -s "$CACHE_FILE" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Le fichier ISO est vide ou corrompu."
  exit 1
fi

# --- CRÉATION VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM (UEFI)..."
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

echo -e "\e[34m[INFO]\e[0m Création du disque et attachment ISO..."
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1,cache=writeback"
qm set "$VMID" --ide2 "$ISO_VOLUME,media=cdrom"
qm set "$VMID" --boot "order=scsi0;ide2"

# --- DÉMARRAGE ---
if [[ "$START_VM" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Arch Linux préparée (ID: $VMID) !"
echo -e "\e[33m====================================================\e[0m"
echo -e "\e[33m 1. Ouvrez la console : qm terminal $VMID\e[0m"
echo -e "\e[33m 2. Connectez-vous en root (mot de passe : root)\e[0m"
echo -e "\e[33m 3. Lancez : archinstall\e[0m"
echo -e "\e[33m 4. Installez qemu-guest-agent : pacman -S qemu-guest-agent\e[0m"
echo -e "\e[33m 5. Après installation, retirez l'ISO : qm set $VMID --ide2 none\e[0m"
echo -e "\e[33m====================================================\e[0m"
