#!/usr/bin/env bash
# ProxForge — WireGuard + WGDashboard (Debian 12) pour Proxmox VE 9.2
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
HN="${HN:-wireguard-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-512}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

[[ "$CTID" =~ ^[0-9]+$ ]]          || fail "CTID invalide : '$CTID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '4G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$CTID" >/dev/null 2>&1 || fail "L'ID $CTID est déjà utilisé."

# Proxmox attend une taille en Go sans unité pour créer un volume (STOCKAGE:4, pas STOCKAGE:4G).
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

# Prépare le périphérique TUN sur l'hôte (nécessaire aux VPN) et le rend persistant au redémarrage :
# sans le module "tun" chargé, le bind-mount de /dev/net/tun ferait échouer le démarrage du conteneur.
ensure_host_tun() {
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
  [[ -c /dev/net/tun ]] || fail "/dev/net/tun absent sur l'hôte et 'modprobe tun' impossible."
  if ! grep -rqs '^tun$' /etc/modules /etc/modules-load.d/ 2>/dev/null; then
    echo "tun" > /etc/modules-load.d/proxforge-tun.conf
    info "Module 'tun' ajouté au chargement automatique de l'hôte (/etc/modules-load.d/proxforge-tun.conf)."
  fi
}

# 4. TEMPLATE
info "Mise à jour des templates..."
pveam update >/dev/null || fail "pveam update échoué."

TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}' || true)
[[ -n "$TEMPLATE_NAME" ]] || fail "Template Debian 12 introuvable."

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -F "vztmpl/${TEMPLATE_FILE}" >/dev/null; then
  ok "Template déjà présent en cache : $TEMPLATE_FILE"
else
  info "Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || fail "Téléchargement du template échoué."
fi

# 5. CRÉATION LXC (avec périphérique TUN)
ensure_host_tun
modprobe wireguard 2>/dev/null || warn "Module 'wireguard' non chargeable sur l'hôte (noyau Proxmox récent : normalement intégré)."

info "Création du conteneur LXC WireGuard (Unprivileged + TUN)..."
# nesting=1 : l'unité systemd de WGDashboard utilise PrivateTmp, qui échoue sinon dans un LXC non privilégié.
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
  --features nesting=1 \
  --description "WireGuard + WGDashboard - ProxForge" >/dev/null || fail "Création du conteneur échouée."
CT_CREATED=1

# TUN indispensable à WireGuard (à ajouter avant le premier démarrage)
{
  echo "lxc.cgroup2.devices.allow: c 10:200 rwm"
  echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
} >> "/etc/pve/lxc/${CTID}.conf"

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  info "Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || fail "Démarrage du conteneur échoué."

  info "Attente du réseau (DHCP)..."
  wait_for_network || fail "Timeout DHCP après 60s."

  info "Installation de WireGuard et WGDashboard (veuillez patienter)..."
  INSTALL_SCRIPT=$(mktemp)
  LOG_FILE=$(mktemp)
  TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

  cat > "$INSTALL_SCRIPT" <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y sudo git iptables iproute2 wireguard-tools net-tools procps curl ca-certificates \
  python3 python3-venv python3-pip

# Routage IPv4 persistant (recommandé pour un serveur VPN)
cat > /etc/sysctl.d/99-proxforge-wireguard.conf <<'CONF'
net.ipv4.ip_forward=1
CONF
sysctl -p /etc/sysctl.d/99-proxforge-wireguard.conf >/dev/null \
  || echo "Impossible d'activer ip_forward dans le conteneur : activez-le sur l'hôte si besoin de routage" >&2

mkdir -p /etc/wireguard

# Installation officielle de WGDashboard : "wgd.sh install" crée lui-même son environnement Python (src/venv)
rm -rf /etc/wgdashboard
git clone --depth 1 https://github.com/WGDashboard/WGDashboard.git /etc/wgdashboard
cd /etc/wgdashboard/src
chmod +x wgd.sh
./wgd.sh install
chmod -R 755 /etc/wireguard

# Service systemd : on utilise le fichier fourni par le projet (lancement via "wgd.sh start", gunicorn)
SRC_DIR=/etc/wgdashboard/src
sed "s#<absolute_path_of_WGDashboard_src>#${SRC_DIR}#g" wg-dashboard.service > /etc/systemd/system/wg-dashboard.service
if grep -q '<absolute_path_of_WGDashboard_src>' /etc/systemd/system/wg-dashboard.service; then
  echo "Le fichier wg-dashboard.service contient encore des chemins non remplacés" >&2
  exit 1
fi
chmod 664 /etc/systemd/system/wg-dashboard.service
systemctl daemon-reload
systemctl enable --now wg-dashboard.service

# Vérification : l'interface web répond
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://localhost:10086 && exit 0
  sleep 2
done
echo "WGDashboard ne répond pas sur :10086 après 120 s" >&2
exit 1
EOS

  if ! run_script_in_ct bash "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
    tail -n 30 "$LOG_FILE" >&2
    fail "Installation de WireGuard / WGDashboard échouée."
  fi
fi

# 7. RÉSULTAT
LXC_IP=""
if [[ "$START_LXC" == "yes" ]]; then
  LXC_IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}' || true)
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC WireGuard + WGDashboard déployé (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
if [[ -n "$LXC_IP" ]]; then
  info "Interface WGDashboard : http://${LXC_IP}:10086"
  info "Identifiants par défaut de WGDashboard : admin / admin"
  warn "Changez ce mot de passe dès la première connexion (Paramètres > Compte) : l'interface écoute sur toutes les adresses."
  info "Port WireGuard à rediriger sur votre box : 51820/UDP (si vous créez une configuration sur ce port)."
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
elif [[ "$START_LXC" == "yes" ]]; then
  warn "IP introuvable : cherchez-la dans l'interface Proxmox (port 10086)."
else
  info "Conteneur non démarré : pct start $CTID, puis installez WGDashboard (START_LXC=yes pour automatiser)."
fi
echo -e ""
