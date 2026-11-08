#!/usr/bin/env bash
# ProxForge — Création automatisée d'un LXC Docker (Debian 13) pour Proxmox VE 9.2
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
HN="${HN:-docker-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

[[ "$CTID" =~ ^[0-9]+$ ]]          || fail "CTID invalide : '$CTID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '8G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$CTID" >/dev/null 2>&1 || fail "L'ID $CTID est déjà utilisé."

# Proxmox attend une taille en Go sans unité pour créer un volume (STOCKAGE:8, pas STOCKAGE:8G).
DISK_GB="${DISK_SIZE%[Gg]}"

# 3. CLEANUP
CT_CREATED=0
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

# 4. TEMPLATE
info "Mise à jour des templates..."
pveam update >/dev/null || fail "pveam update échoué."

info "Recherche du template Debian 13..."
TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-13-standard" | sort -V | tail -n 1 | awk '{print $2}' || true)
[[ -n "$TEMPLATE_NAME" ]] || fail "Template Debian 13 introuvable."

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -F "vztmpl/${TEMPLATE_FILE}" >/dev/null; then
  ok "Template déjà présent en cache : $TEMPLATE_FILE"
else
  info "Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || fail "Téléchargement du template échoué."
fi

# 5. CRÉATION LXC
info "Création du conteneur LXC Docker (Unprivileged)..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype debian \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --unprivileged 1 \
  --onboot 1 \
  --features nesting=1,keyctl=1 \
  --description "Docker LXC - ProxForge" >/dev/null || fail "Création du conteneur échouée."
CT_CREATED=1

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  info "Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || fail "Démarrage du conteneur échoué."

  info "Attente du réseau (DHCP)..."
  wait_for_network || fail "Timeout DHCP après 60s."

  info "Installation de Docker (veuillez patienter)..."
  INSTALL_SCRIPT=$(mktemp)
  LOG_FILE=$(mktemp)
  TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

  cat > "$INSTALL_SCRIPT" <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates gnupg

# Configuration écrite AVANT l'installation pour être prise en compte au premier démarrage du démon.
# Le storage-driver n'est pas forcé : Docker choisit lui-même (overlay2 si supporté, sinon un fallback).
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON

# Script officiel téléchargé puis exécuté (pas de pipe direct vers sh) ; il installe aussi le plugin compose.
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

systemctl enable --now docker
docker info >/dev/null
docker --version
docker compose version
EOS

  if ! run_script_in_ct bash "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
    tail -n 30 "$LOG_FILE" >&2
    fail "Installation de Docker échouée."
  fi
fi

# 7. RÉSULTAT
LXC_IP=""
if [[ "$START_LXC" == "yes" ]]; then
  LXC_IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}' || true)
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC Docker déployé avec succès (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
info "Accès : pct enter $CTID  (le compte root n'a pas de mot de passe SSH par défaut)"
if [[ -n "$LXC_IP" ]]; then
  info "IP du conteneur : ${LXC_IP}"
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
elif [[ "$START_LXC" == "yes" ]]; then
  warn "IP introuvable : cherchez-la dans l'interface Proxmox ou avec : pct exec $CTID -- ip a"
else
  info "Conteneur non démarré : pct start $CTID, puis installez Docker (START_LXC=yes pour automatiser)."
fi
echo -e ""
