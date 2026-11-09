#!/usr/bin/env bash
# ProxForge — Création automatisée d'une VM Docker (Debian 13 Cloud-Init) pour Proxmox VE 9.2
set -euo pipefail

info() { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[AVERTISSEMENT]\e[0m $*" >&2; }
fail() { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }

gen_password() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

# ============================================================================
# 1. VALIDATIONS PRÉCOCES
# ============================================================================

[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root."

for cmd in curl qm pvesh pvesm awk base64; do
  command -v "$cmd" >/dev/null 2>&1 || fail "La commande '$cmd' est requise mais introuvable."
done

[[ "$(uname -m)" == "x86_64" ]] || fail "Architecture '$(uname -m)' non supportée (x86_64 uniquement)."

# ============================================================================
# 2. CONFIGURATION
# ============================================================================

VMID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-docker-vm-$VMID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-4096}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"   # stockage avec le contenu "snippets" activé

# Cloud-Init
CIUSER="${CIUSER:-docker}"
CIPASSWORD="${CIPASSWORD:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"
NAMESERVER="${NAMESERVER:-}"                  # vide = DNS fournis par le DHCP

[[ "$VMID" =~ ^[0-9]+$ ]]          || fail "VMID invalide : '$VMID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '20G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || fail "L'ID $VMID est déjà utilisé."

if [[ -n "$SSH_PUBKEY_FILE" && ! -f "$SSH_PUBKEY_FILE" ]]; then
  fail "Clé SSH introuvable : $SSH_PUBKEY_FILE"
fi

if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1 {print $1}' | grep -x "$SNIPPET_STORAGE" >/dev/null; then
  fail "Le stockage '$SNIPPET_STORAGE' n'a pas le contenu 'snippets' activé (Datacenter > Storage > Edit > Content), ou précisez SNIPPET_STORAGE=..."
fi

# Mot de passe : fourni, ou généré si aucune clé SSH n'est donnée (jamais de mot de passe par défaut public).
PW_GENERATED=0
if [[ -z "$CIPASSWORD" && -z "$SSH_PUBKEY_FILE" ]]; then
  CIPASSWORD=$(gen_password)
  PW_GENERATED=1
fi

# ============================================================================
# 3. CACHE ET NETTOYAGE
# ============================================================================

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "$LOCAL_CACHE_DIR"

VM_CREATED=0
SNIPPET_PATH=""
TMP_FILES=()

cleanup() {
  local exit_code=$?
  set +e
  trap - EXIT
  for f in "${TMP_FILES[@]}"; do rm -rf -- "$f" 2>/dev/null; done
  if (( exit_code != 0 )); then
    if (( VM_CREATED )); then
      warn "Échec : suppression de la VM $VMID..."
      qm stop "$VMID" >/dev/null 2>&1
      qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1
    fi
    [[ -n "$SNIPPET_PATH" ]] && rm -f -- "$SNIPPET_PATH"
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

info "Début de la création de la VM Docker (ID: $VMID)..."

# ============================================================================
# 4. TÉLÉCHARGEMENT DEBIAN 13 (Trixie)
# ============================================================================

CACHE_FILE="${LOCAL_CACHE_DIR}/debian-13-cloud-amd64.qcow2"
URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"

if [[ -f "$CACHE_FILE" ]]; then
  ok "Image Debian 13 déjà présente : $CACHE_FILE"
else
  info "Téléchargement de l'image Debian 13 Cloud-Init..."
  download_file "$URL" "$CACHE_FILE"
fi

# ============================================================================
# 5. CRÉATION DE LA VM
# ============================================================================

info "Création de la VM..."
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
  --description "Docker VM - ProxForge" >/dev/null || fail "Création de la VM échouée."
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1" >/dev/null || fail "Création du disque EFI échouée."

info "Importation du disque..."
# Pas de --format : qcow2 n'est pas valide sur les stockages bloc (LVM-thin, ZFS),
# Proxmox choisit le bon format selon le stockage cible.
qm importdisk "$VMID" "$CACHE_FILE" "$STORAGE" >/dev/null || fail "Échec de l'importation du disque."

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
# 6. CLOUD-INIT (utilisateur/réseau via Proxmox, installation de Docker via snippet "vendor")
# ============================================================================

# Un snippet "vendor" s'ajoute au user-data généré par Proxmox (ciuser, cipassword, sshkeys)
# au lieu de le remplacer. Les commandes "qm cloudinit push/dump --user" de l'ancienne version n'existent pas.
SNIPPET_NAME="docker-vendor-${VMID}.yml"
SNIPPET_PATH=$(pvesm path "${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}") || fail "Chemin du snippet introuvable."
mkdir -p "$(dirname "$SNIPPET_PATH")"

cat > "$SNIPPET_PATH" <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
  - gnupg

write_files:
  - path: /etc/docker/daemon.json
    permissions: '0644'
    content: |
      {
        "log-driver": "json-file",
        "log-opts": { "max-size": "10m", "max-file": "3" }
      }

runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsSL https://get.docker.com -o /root/get-docker.sh
  - sh /root/get-docker.sh
  - rm -f /root/get-docker.sh
  - systemctl enable --now docker
  - usermod -aG docker ${CIUSER}

final_message: "VM Docker prête après \$UPTIME secondes."
EOF

CI_ARGS=(--ciuser "$CIUSER" --ipconfig0 "$IPCONFIG0" --cicustom "vendor=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}")
if [[ -n "$SSH_PUBKEY_FILE" ]]; then CI_ARGS+=(--sshkeys "$SSH_PUBKEY_FILE"); fi
if [[ -n "$CIPASSWORD" ]];      then CI_ARGS+=(--cipassword "$CIPASSWORD"); fi
if [[ -n "$NAMESERVER" ]];      then CI_ARGS+=(--nameserver "$NAMESERVER"); fi
qm set "$VMID" "${CI_ARGS[@]}" >/dev/null || fail "Configuration Cloud-Init échouée."

# ============================================================================
# 7. DÉMARRAGE
# ============================================================================

STARTED="non"
if [[ "$START_VM" == "yes" ]]; then
  info "Démarrage de la VM Docker..."
  if qm start "$VMID" >/dev/null; then STARTED="oui"; else warn "Échec du démarrage de la VM $VMID."; fi
fi

# La création a réussi : le snippet doit rester associé à la VM.
SNIPPET_PATH=""

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  VM Docker déployée avec succès (ID: $VMID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
info "Utilisateur : $CIUSER  |  VM démarrée : $STARTED"
if (( PW_GENERATED )); then
  echo -e "\e[33m[IMPORTANT]\e[0m Mot de passe généré : ${CIPASSWORD}  (notez-le et changez-le)"
fi
info "Docker s'installe au premier démarrage (2 à 5 minutes selon la connexion)."
info "IP (une fois l'agent QEMU actif) : qm guest cmd $VMID network-get-interfaces"
echo -e "\e[31m[⚠️]\e[0m Fixez l'IP de la VM en statique (bail DHCP du routeur ou IPCONFIG0=ip=X.X.X.X/24,gw=X.X.X.X)."
echo -e ""
