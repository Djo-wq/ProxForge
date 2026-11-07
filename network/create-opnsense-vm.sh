#!/usr/bin/env bash
# Script de création automatisée VM OPNsense (via FreeBSD) (Optimisé)
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-opnsense-vm}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-8192}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
LAN_BRG="${LAN_BRG:-vmbr0}"
WAN_BRG="${WAN_BRG:-vmbr1}"
START_VM="${START_VM:-yes}"
OPNSENSE_VERSION="24.7"
FREEBSD_MAJOR="14"

# --- SÉCURITÉ NETTOYAGE ---
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de création de la VM OPNsense (ID: $VMID)..."

function send_line_to_vm() {
  local text="$1"
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    case "$char" in
      " ") char="spc" ;; "-") char="minus" ;; "=") char="equal" ;; ",") char="comma" ;;
      ".") char="dot" ;; "/") char="slash" ;; "'") char="apostrophe" ;; ";") char="semicolon" ;;
      '\') char="backslash" ;; "_") char="shift-minus" ;; '"') char="shift-apostrophe" ;;
      *) [[ "$char" =~ [A-Z] ]] && char="shift-$(echo "$char" | tr '[:upper:]' '[:lower:]')" ;;
    esac
    qm sendkey "$VMID" "$char"
  done
  qm sendkey "$VMID" ret
}

# --- TÉLÉCHARGEMENT ET DÉCOMPRESSION ATOMIQUES ---
BASE_URL="https://download.freebsd.org/releases/VM-IMAGES/${FREEBSD_MAJOR}.1-RELEASE/amd64/Latest"
FILE_URL="${BASE_URL}/FreeBSD-${FREEBSD_MAJOR}.1-RELEASE-amd64-zfs.qcow2.xz"

CACHE_FILE="${LOCAL_CACHE_DIR}/FreeBSD-${FREEBSD_MAJOR}.1-zfs.qcow2.xz"
DECOMPRESSED_FILE="${LOCAL_CACHE_DIR}/FreeBSD-${FREEBSD_MAJOR}.1-zfs.qcow2"

if [ ! -f "$DECOMPRESSED_FILE" ]; then
  if [ ! -f "$CACHE_FILE" ]; then
    echo -e "\e[34m[INFO]\e[0m Téléchargement de FreeBSD $FREEBSD_MAJOR..."
    curl -fL --progress-bar -o "${CACHE_FILE}.tmp" "$FILE_URL"
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
  fi
  echo -e "\e[34m[INFO]\e[0m Décompression de l'image de base (Veuillez patienter)..."
  # Décompression atomique pour éviter une image corrompue en cas d'arrêt
  xz -d -c "$CACHE_FILE" > "${DECOMPRESSED_FILE}.tmp"
  mv "${DECOMPRESSED_FILE}.tmp" "$DECOMPRESSED_FILE"
fi

# --- CRÉATION DE LA VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM OPNsense (Machine i440fx)..."
qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine i440fx --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 virtio,bridge="$LAN_BRG",firewall=0,queues="$CPU_CORES" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci

if [ -n "$WAN_BRG" ]; then
  qm set "$VMID" --net1 virtio,bridge="$WAN_BRG",firewall=0,queues="$CPU_CORES"
fi

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Importation du disque FreeBSD..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$DECOMPRESSED_FILE" "$STORAGE" --format qcow2)
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

# FIX : cache=writeback ajouté
qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- BOOTSTRAP OPNsense ---
if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
  
  echo -e "\e[33m[ATTENTION]\e[0m Attente du démarrage de FreeBSD (60s)..."
  sleep 60

  echo -e "\e[34m[INFO]\e[0m Injection du script Bootstrap OPNsense..."
  send_line_to_vm "root"
  sleep 2
  send_line_to_vm ""
  send_line_to_vm "fetch -q https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in"
  sleep 3
  send_line_to_vm "echo \"PRAGMA foreign_keys=ON; DELETE FROM packages WHERE name LIKE 'FreeBSD-%';\" | pkg shell"
  sleep 5
  send_line_to_vm "sh ./opnsense-bootstrap.sh.in -y -f -r ${OPNSENSE_VERSION}"
  
  echo -e "\e[33m[ACTION REQUISE]\e[0m Ouvrez la console de la VM pour suivre la fin de l'installation !"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m Création de la VM OPNsense (ID: $VMID) terminée."
