#!/usr/bin/env bash
# ProxForge — Création d'une VM Arch Linux, installation manuelle (Proxmox VE 9.2)
set -euo pipefail

info() { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[AVERTISSEMENT]\e[0m $*" >&2; }
fail() { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }

# ============================================================================
# 1. VALIDATIONS PRÉCOCES
# ============================================================================

[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root."

for cmd in curl qm pvesh awk; do
  command -v "$cmd" >/dev/null 2>&1 || fail "La commande '$cmd' est requise mais introuvable."
done

# ============================================================================
# 2. CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-arch-linux-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
ISO_STORAGE="${ISO_STORAGE:-local}"   # stockage qui contient les ISO (≠ STORAGE, qui héberge les disques)
REFRESH_ISO="${REFRESH_ISO:-no}"      # yes = retélécharger l'ISO même si elle est en cache

[[ "$VMID" =~ ^[0-9]+$ ]]          || fail "VMID invalide : '$VMID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '20G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || fail "L'ID $VMID est déjà utilisé."

# Proxmox attend une taille en Go sans unité pour créer un disque (STOCKAGE:20, pas STOCKAGE:20G).
DISK_GB="${DISK_SIZE%[Gg]}"

# ============================================================================
# 3. CACHE ET NETTOYAGE
# ============================================================================

LOCAL_ISO_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_ISO_DIR"

VM_CREATED=0
TMP_FILES=()

cleanup() {
  local exit_code=$?
  set +e
  trap - EXIT
  for f in "${TMP_FILES[@]}"; do rm -rf -- "$f" 2>/dev/null; done
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    warn "Échec : suppression de la VM $VMID..."
    qm stop "$VMID" >/dev/null 2>&1
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download_file() { # $1 = URL, $2 = destination
  local url="$1" dest="$2"
  TMP_FILES+=("${dest}.tmp")
  curl -fL --retry 3 --progress-bar -o "${dest}.tmp" "$url" || fail "Échec du téléchargement : $url"
  mv -f "${dest}.tmp" "$dest"
}

# ============================================================================
# 4. TÉLÉCHARGEMENT DE L'ISO
# ============================================================================

URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
ISO_FILE="archlinux-latest-x86_64.iso"
CACHE_FILE="${LOCAL_ISO_DIR}/${ISO_FILE}"

if [[ -f "$CACHE_FILE" && "$REFRESH_ISO" != "yes" ]]; then
  ok "ISO Arch Linux déjà présente : $CACHE_FILE (REFRESH_ISO=yes pour la mettre à jour)"
else
  info "Téléchargement de l'ISO Arch Linux..."
  download_file "$URL" "$CACHE_FILE"
fi

# ============================================================================
# 5. CRÉATION DE LA VM
# ============================================================================

info "Création de la VM (ID: $VMID)..."
qm create "$VMID" \
  --name "$HN" \
  --agent 1 \
  --bios ovmf \
  --machine q35 \
  --cpu host \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 \
  --onboot 1 \
  --scsihw virtio-scsi-pci \
  --description "Arch Linux - ProxForge" >/dev/null || fail "Création de la VM échouée."
VM_CREATED=1

# pre-enrolled-keys=0 : l'ISO Arch n'est pas signée pour le Secure Boot,
# avec les clés Microsoft pré-enrôlées elle refuserait de démarrer.
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" >/dev/null || fail "Création du disque EFI échouée."
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_GB},discard=on,ssd=1,cache=writeback" >/dev/null || fail "Création du disque système échouée."
qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${ISO_FILE},media=cdrom" >/dev/null || fail "Attachement de l'ISO échoué (stockage '${ISO_STORAGE}')."
qm set "$VMID" --boot "order=ide2;scsi0" >/dev/null || fail "Configuration de l'ordre de boot échouée."

# ============================================================================
# 6. DÉMARRAGE
# ============================================================================

STARTED="non"
if [[ "$START_VM" == "yes" ]]; then
  info "Démarrage de la VM..."
  if qm start "$VMID" >/dev/null; then STARTED="oui"; else warn "Échec du démarrage de la VM $VMID."; fi
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  VM Arch Linux déployée avec succès (ID: $VMID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
info "VM démarrée : $STARTED"
info "1. Ouvrez la console de la VM dans Proxmox"
info "2. Lancez : archinstall"
info "3. Installez sur /dev/sda"
info "4. Après installation, retirez l'ISO : qm set $VMID --ide2 none,media=cdrom"
echo -e ""
