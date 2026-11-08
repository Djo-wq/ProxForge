#!/usr/bin/env bash
# ProxForge — Création automatisée d'une VM Ubuntu Cloud-Init (Proxmox VE 9.2)
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

[[ "$(uname -m)" == "x86_64" ]] || fail "Architecture '$(uname -m)' non supportée (x86_64 uniquement)."

# ============================================================================
# 2. CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-ubuntu-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"

# Cloud-Init
CIUSER="${CIUSER:-ubuntu}"
CIPASSWORD="${CIPASSWORD:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"

[[ "$VMID" =~ ^[0-9]+$ ]]          || fail "VMID invalide : '$VMID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '20G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || fail "L'ID $VMID est déjà utilisé."

if [[ -n "$SSH_PUBKEY_FILE" && ! -f "$SSH_PUBKEY_FILE" ]]; then
  fail "Clé SSH introuvable : $SSH_PUBKEY_FILE"
fi

case "$UBUNTU_VERSION" in
  24.04) UBUNTU_CODENAME="noble" ;;
  22.04) UBUNTU_CODENAME="jammy" ;;
  20.04) UBUNTU_CODENAME="focal" ;;
  18.04) UBUNTU_CODENAME="bionic" ;;
  *) fail "Version Ubuntu '$UBUNTU_VERSION' non supportée." ;;
esac

# ============================================================================
# 3. CACHE ET NETTOYAGE
# ============================================================================

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_CACHE_DIR"

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
# 4. TÉLÉCHARGEMENT
# ============================================================================

WORK_FILE="${LOCAL_CACHE_DIR}/ubuntu-${UBUNTU_VERSION}-cloud-amd64.img"
URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"

if [[ -f "$WORK_FILE" ]]; then
  ok "Image Ubuntu déjà présente : $WORK_FILE"
else
  info "Téléchargement de l'image Ubuntu ${UBUNTU_VERSION}..."
  download_file "$URL" "$WORK_FILE"
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
  --description "Ubuntu ${UBUNTU_VERSION} - ProxForge" >/dev/null || fail "Création de la VM échouée."
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1" >/dev/null || fail "Création du disque EFI échouée."

info "Importation du disque..."
# Pas de --format : qcow2 n'est pas valide sur les stockages bloc (LVM-thin, ZFS),
# Proxmox choisit le bon format selon le stockage cible.
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" >/dev/null || fail "Échec de l'importation du disque."

DISK_VOL=$(qm config "$VMID" | awk '/^unused0:/ {sub(/^unused0:[[:space:]]*/, ""); print; exit}')
[[ -n "$DISK_VOL" ]] || fail "Impossible d'identifier le disque importé."

qm set "$VMID" \
  --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket >/dev/null || fail "Attachement du disque échoué."

qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null \
  || warn "Redimensionnement à ${DISK_SIZE} impossible (taille inférieure à l'image ?). Taille d'origine conservée."

# ============================================================================
# 6. CLOUD-INIT
# ============================================================================

CI_ARGS=(--ciuser "$CIUSER" --ipconfig0 "$IPCONFIG0")
if [[ -n "$SSH_PUBKEY_FILE" ]]; then CI_ARGS+=(--sshkeys "$SSH_PUBKEY_FILE"); fi
if [[ -n "$CIPASSWORD" ]];      then CI_ARGS+=(--cipassword "$CIPASSWORD"); fi
qm set "$VMID" "${CI_ARGS[@]}" >/dev/null || fail "Configuration Cloud-Init échouée."

if [[ -z "$CIPASSWORD" && -z "$SSH_PUBKEY_FILE" ]]; then
  warn "Aucun mot de passe ni clé SSH : relancez avec CIPASSWORD=... ou SSH_PUBKEY_FILE=... (ou configurez Cloud-Init dans l'interface) sinon la VM sera inaccessible."
fi

# ============================================================================
# 7. DÉMARRAGE
# ============================================================================

STARTED="non"
if [[ "$START_VM" == "yes" ]]; then
  info "Démarrage de la VM..."
  if qm start "$VMID" >/dev/null; then STARTED="oui"; else warn "Échec du démarrage de la VM $VMID."; fi
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  VM Ubuntu ${UBUNTU_VERSION} déployée avec succès (ID: $VMID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
info "Utilisateur Cloud-Init : $CIUSER  |  VM démarrée : $STARTED"
info "IP (une fois l'agent QEMU actif) : qm guest cmd $VMID network-get-interfaces"
echo -e "\e[31m[⚠️]\e[0m Fixez l'IP de la VM en statique (bail DHCP du routeur ou IPCONFIG0=ip=X.X.X.X/24,gw=X.X.X.X)."
echo -e ""
