#!/usr/bin/env bash
# ProxForge — Jellyfin (Ubuntu 24.04) pour Proxmox VE 9.2
set -euo pipefail

info() { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[AVERTISSEMENT]\e[0m $*" >&2; }
fail() { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }

# 1. VALIDATIONS
[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root."
for cmd in pct pveam pvesh awk; do
  command -v "$cmd" >/dev/null 2>&1 || fail "La commande '$cmd' est requise mais introuvable."
done

# 2. CONFIGURATION
CTID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-jellyfin-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-16G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"

[[ "$CTID" =~ ^[0-9]+$ ]]          || fail "CTID invalide : '$CTID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '16G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$CTID" >/dev/null 2>&1 || fail "L'ID $CTID est déjà utilisé."

# Proxmox attend une taille en Go sans unité pour créer un volume (STOCKAGE:16, pas STOCKAGE:16G).
DISK_GB="${DISK_SIZE%[Gg]}"

# 3. CLEANUP
CT_CREATED=0
GPU_ENABLED=0
TMP_FILES=()

cleanup() {
  local exit_code=$?
  set +e
  trap - EXIT
  for f in "${TMP_FILES[@]}"; do rm -rf -- "$f" 2>/dev/null; done
  if (( exit_code != 0 )) && (( CT_CREATED )); then
    warn "Échec : suppression du conteneur $CTID..."
    pct stop "$CTID" >/dev/null 2>&1
    pct destroy "$CTID" --purge 1 >/dev/null 2>&1
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_network() { # attend une connectivité réseau dans le conteneur (timeout 60 s)
  local i
  for ((i = 0; i < 60; i++)); do
    if pct exec "$CTID" -- ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

run_script_in_ct() { # $1 = interpréteur (bash|ash), $2 = script local ; le script est supprimé du conteneur ensuite
  local shell="$1" script="$2" rc=0
  pct push "$CTID" "$script" /root/proxforge-install.sh --perms 0700 || return 1
  pct exec "$CTID" -- "$shell" /root/proxforge-install.sh || rc=$?
  pct exec "$CTID" -- rm -f /root/proxforge-install.sh >/dev/null 2>&1 || true
  return "$rc"
}

# Passthrough du GPU (nœud de rendu) vers le conteneur. Doit être appelé conteneur démarré.
# On utilise l'option "dev0" de Proxmox (≥ 8.1) avec le GID du groupe "render" DU CONTENEUR :
# un simple bind-mount (lxc.mount.entry) donne un nœud illisible pour un conteneur non privilégié
# (propriétaire hôte non mappé), donc Jellyfin n'y aurait pas accès.
setup_gpu_passthrough() {
  local gid
  if [[ ! -c "$RENDER_NODE" ]]; then
    info "Aucun GPU détecté ($RENDER_NODE absent) : transcodage 100% logiciel (CPU)."
    return 0
  fi
  info "GPU détecté ($RENDER_NODE) : configuration du passthrough..."

  gid=$(pct exec "$CTID" -- getent group render 2>/dev/null | awk -F: '{print $3}' || true)
  if [[ -z "$gid" ]]; then
    pct exec "$CTID" -- groupadd -r render >/dev/null 2>&1 || true
    gid=$(pct exec "$CTID" -- getent group render 2>/dev/null | awk -F: '{print $3}' || true)
  fi
  if [[ -z "$gid" ]]; then
    warn "Groupe 'render' introuvable dans le conteneur : passthrough GPU ignoré."
    return 0
  fi

  if ! pct set "$CTID" --dev0 "${RENDER_NODE},gid=${gid}" >/dev/null 2>&1; then
    warn "Échec de 'pct set --dev0' (Proxmox VE 8.1 minimum requis) : passthrough GPU ignoré."
    return 0
  fi

  info "Redémarrage du conteneur pour appliquer le périphérique..."
  pct reboot "$CTID" >/dev/null || fail "Redémarrage du conteneur échoué."
  wait_for_network || fail "Timeout DHCP après 60s (après redémarrage)."
  GPU_ENABLED=1
}

# 4. TEMPLATE
info "Mise à jour des templates..."
pveam update >/dev/null || fail "pveam update échoué."

TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "ubuntu-24.04-standard" | sort -V | tail -n 1 | awk '{print $2}' || true)
[[ -n "$TEMPLATE_NAME" ]] || fail "Template Ubuntu 24.04 introuvable."

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -F "vztmpl/${TEMPLATE_FILE}" >/dev/null; then
  ok "Template déjà présent en cache : $TEMPLATE_FILE"
else
  info "Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || fail "Téléchargement du template échoué."
fi

# 5. CRÉATION LXC
info "Création du conteneur LXC Jellyfin (Unprivileged)..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype ubuntu \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --unprivileged 1 \
  --onboot 1 \
  --features nesting=1 \
  --description "Jellyfin - ProxForge" >/dev/null || fail "Création du conteneur échouée."
CT_CREATED=1

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  info "Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || fail "Démarrage du conteneur échoué."

  info "Attente du réseau (DHCP)..."
  wait_for_network || fail "Timeout DHCP après 60s."

  setup_gpu_passthrough

  info "Installation de Jellyfin (veuillez patienter)..."
  INSTALL_SCRIPT=$(mktemp)
  LOG_FILE=$(mktemp)
  TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

  {
    printf 'GPU_ENABLED=%q\n' "$GPU_ENABLED"
    cat <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl gnupg ca-certificates apt-transport-https

# Clé GPG et dépôt officiels Jellyfin
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/jellyfin.gpg
[ -s /etc/apt/keyrings/jellyfin.gpg ] || { echo "Clé GPG Jellyfin introuvable" >&2; exit 1; }

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
cat > /etc/apt/sources.list.d/jellyfin.sources <<SRC
Types: deb
URIs: https://repo.jellyfin.org/ubuntu
Suites: ${CODENAME}
Components: main
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/jellyfin.gpg
SRC

# Le paquet "jellyfin" tire lui-même la bonne version de jellyfin-ffmpeg : on ne la fige pas
# (un nom de paquet ffmpeg codé en dur casse dès que Jellyfin change de version majeure d'ffmpeg).
apt-get update -y
apt-get install -y jellyfin libjemalloc2

# Optimisation mémoire (jemalloc)
JEMALLOC=$(find /usr/lib -name 'libjemalloc.so.2' -print -quit)
[ -z "$JEMALLOC" ] || ln -sf "$JEMALLOC" /usr/lib/libjemalloc.so

# Pilotes VA-API et accès au nœud de rendu si un GPU a été transmis
if [ "$GPU_ENABLED" = "1" ]; then
  apt-get install -y vainfo mesa-va-drivers || echo "Pilotes Mesa VA-API non installés" >&2
  apt-get install -y intel-media-va-driver || echo "Pilote Intel VA-API non installé (normal sans GPU Intel)" >&2
  usermod -aG render jellyfin
fi

systemctl enable jellyfin
systemctl restart jellyfin

# Vérification : l'endpoint /health répond "Healthy" une fois le service prêt
for _ in $(seq 1 60); do
  curl -fsS http://localhost:8096/health >/dev/null 2>&1 && exit 0
  sleep 2
done
echo "Jellyfin met du temps à démarrer (pas de réponse sur :8096 après 120 s)" >&2
EOS
  } > "$INSTALL_SCRIPT"

  if ! run_script_in_ct bash "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
    tail -n 30 "$LOG_FILE" >&2
    fail "Installation de Jellyfin échouée."
  fi
  if grep -F "met du temps à démarrer" "$LOG_FILE" >/dev/null; then
    warn "Jellyfin ne répondait pas encore à la fin de l'installation : patientez puis ouvrez l'interface."
  fi
fi

# 7. RÉSULTAT
LXC_IP=""
if [[ "$START_LXC" == "yes" ]]; then
  LXC_IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}' || true)
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC Jellyfin déployé avec succès (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
if [[ -n "$LXC_IP" ]]; then
  info "Interface : http://${LXC_IP}:8096 (assistant de configuration au premier accès)"
  if (( GPU_ENABLED )); then
    info "GPU transmis : activez VA-API (/dev/dri/renderD128) dans Jellyfin > Tableau de bord > Lecture."
  fi
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
elif [[ "$START_LXC" == "yes" ]]; then
  warn "IP introuvable : cherchez-la dans l'interface Proxmox (port 8096)."
else
  info "Conteneur non démarré : pct start $CTID, puis installez Jellyfin (START_LXC=yes pour automatiser, GPU compris)."
fi
echo -e ""
