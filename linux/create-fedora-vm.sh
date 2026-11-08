#!/usr/bin/env bash
# ProxForge — Création automatisée d'une VM Fedora Cloud-Init (Optimisé)
#
# Usage :
#   bash linux/create-fedora-vm.sh
#   CPU_CORES=8 RAM_SIZE=16384 DISK_SIZE=100G STORAGE=local-zfs bash linux/create-fedora-vm.sh
#
# Variables Cloud-Init (nouveau) :
#   CIUSER          utilisateur créé dans la VM            (défaut : admin)
#   CIPASSWORD      mot de passe initial                  (optionnel)
#   SSH_PUBKEY_FILE chemin d'une clé publique à injecter (optionnel, ex : /root/.ssh/id_ed25519.pub)
#   IPCONFIG0       configuration réseau cloud-init       (défaut : ip=dhcp)

set -euo pipefail

# --- CONFIGURATION (surchargeable via variables d'environnement) ---
HN="${HN:-fedora-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
VMID="${VMID:-$(pvesh get /cluster/nextid)}"

# --- CLOUD-INIT : identifiants de connexion ---
CIUSER="${CIUSER:-admin}"
CIPASSWORD="${CIPASSWORD:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"

# Validation précoce (avant toute création)
if [[ -n "$SSH_PUBKEY_FILE" && ! -f "$SSH_PUBKEY_FILE" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Le fichier de clé SSH '$SSH_PUBKEY_FILE' est introuvable."
  exit 1
fi
if [[ -z "$CIPASSWORD" && -z "$SSH_PUBKEY_FILE" ]]; then
  echo -e "\e[33m[ATTENTION]\e[0m Ni CIPASSWORD ni SSH_PUBKEY_FILE ne sont définis :"
  echo -e "\e[33m[ATTENTION]\e[0m l'utilisateur '$CIUSER' ne pourra pas se connecter sans l'onglet Cloud-Init de l'interface."
fi

# --- SÉCURITÉ / NETTOYAGE ---
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f -- "${LOCAL_CACHE_DIR}"/*.tmp 2>/dev/null || true
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Échec du script : suppression de la VM partiellement créée (ID: ${VMID})..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Fedora (ID: ${VMID})..."

# --- DÉTECTION DE LA DERNIÈRE VERSION FEDORA ---
MIRROR="https://dl.fedoraproject.org/pub/fedora/linux/releases"
ARCH=$(uname -m)

# '|| true' rend le fallback réellement atteignable si le miroir est inaccessible
FEDORA_RELEASE=$(curl -fsSL "${MIRROR}/" \
  | grep -oP 'href="\K[0-9]+(?=/")' | sort -rn | head -n 1 || true)
FEDORA_RELEASE="${FEDORA_RELEASE:-43}" # fallback : dernière version stable connue

IMAGE_DIR="${MIRROR}/${FEDORA_RELEASE}/Cloud/${ARCH}/images"
FILE=$(curl -fsSL "${IMAGE_DIR}/" \
  | grep -oP 'href="\KFedora-Cloud-Base-Generic-[^"]+\.'"${ARCH}"'\.qcow2(?=")' \
  | sort -V | tail -n 1 || true)

if [[ -z "$FILE" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver l'image Fedora Cloud ${FEDORA_RELEASE} (${ARCH})."
  echo -e "\e[31m[ERREUR]\e[0m Vérifiez l'accès Internet du nœud ou le format du miroir."
  exit 1
fi

URL="${IMAGE_DIR}/${FILE}"
WORK_FILE="${LOCAL_CACHE_DIR}/fedora-${FEDORA_RELEASE}-cloud-${ARCH}.qcow2"

# --- TÉLÉCHARGEMENT ATOMIQUE AVEC CACHE LOCAL ---
if [[ -f "$WORK_FILE" ]]; then
  echo -e "\e[32m[OK]\e[0m Image déjà présente en cache local : ${WORK_FILE}"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement de Fedora ${FEDORA_RELEASE} vers le cache local..."
  curl -fL --progress-bar -o "${WORK_FILE}.tmp" "$URL"
  mv -f "${WORK_FILE}.tmp" "$WORK_FILE"
fi

# --- CRÉATION DE LA VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM..."
qm create "$VMID" --name "$HN" --agent 1 --bios ovmf --machine q35 --cpu host \
  --cores "$CPU_CORES" --memory "$RAM_SIZE" --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 --onboot 1 --scsihw virtio-scsi-pci
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel..."
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2

# Volume récupéré depuis la config de la VM (plus robuste que le parsing du message de sortie)
DISK_VOL=$(qm config "$VMID" | awk '/^unused0:/ {sub(/^unused0:[[:space:]]*/, ""); print; exit}')
if [[ -z "$DISK_VOL" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible d'identifier le disque importé (unused0 absent de la config)."
  exit 1
fi

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- CONFIGURATION CLOUD-INIT : identifiants ---
echo -e "\e[34m[INFO]\e[0m Configuration Cloud-Init (utilisateur : ${CIUSER})..."
CI_ARGS=(--ciuser "$CIUSER" --ipconfig0 "$IPCONFIG0")
if [[ -n "$SSH_PUBKEY_FILE" ]]; then
  CI_ARGS+=(--sshkeys "$SSH_PUBKEY_FILE")
fi
if [[ -n "$CIPASSWORD" ]]; then
  CI_ARGS+=(--cipassword "$CIPASSWORD")
fi
qm set "$VMID" "${CI_ARGS[@]}"

if [[ "$START_VM" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Fedora ${FEDORA_RELEASE} créée avec succès (ID: ${VMID}) !"
if [[ -n "$SSH_PUBKEY_FILE" ]]; then
  echo -e "\e[32m[INFO]\e[0m Connexion : ssh ${CIUSER}@<IP_DE_LA_VM>"
fi
