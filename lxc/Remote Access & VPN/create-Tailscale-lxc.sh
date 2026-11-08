#!/usr/bin/env bash
# ProxForge — Ajout de Tailscale sur un LXC existant (Proxmox VE 9.2)
# Usage : bash create-Tailscale-lxc.sh [CTID]     ou     CTID=105 bash create-Tailscale-lxc.sh
set -euo pipefail

info() { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[AVERTISSEMENT]\e[0m $*" >&2; }
fail() { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }

# 1. VALIDATIONS
[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root."
for cmd in pct awk; do
  command -v "$cmd" >/dev/null 2>&1 || fail "La commande '$cmd' est requise mais introuvable."
done

# 2. CONFIGURATION
AUTO_REBOOT="${AUTO_REBOOT:-no}"   # yes = redémarre sans demander si le conteneur tournait déjà
CTID="${CTID:-${1:-}}"
if [[ -z "$CTID" ]]; then
  [[ -t 0 ]] || fail "CTID manquant : passez-le en argument ou via CTID=... (pas de terminal interactif)."
  read -r -p "Entrez l'ID du conteneur LXC (CTID) sur lequel installer Tailscale : " CTID
fi
[[ "$CTID" =~ ^[0-9]+$ ]] || fail "CTID invalide : '$CTID'."
pct status "$CTID" >/dev/null 2>&1 || fail "Le LXC $CTID n'existe pas sur ce nœud."

CONF="/etc/pve/lxc/${CTID}.conf"
[[ -f "$CONF" ]] || fail "Fichier de configuration introuvable : $CONF"

# 3. CLEANUP (fichiers temporaires uniquement : on ne supprime jamais un conteneur existant)
TMP_FILES=()

cleanup() {
  local exit_code=$?
  set +e
  trap - EXIT
  for f in "${TMP_FILES[@]}"; do rm -rf -- "$f" 2>/dev/null; done
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

run_script_in_ct() { # $1 = interpréteur, $2 = script local ; le script est supprimé du conteneur ensuite
  local shell="$1" script="$2" rc=0
  pct push "$CTID" "$script" /root/proxforge-install.sh --perms 0700 || return 1
  pct exec "$CTID" -- "$shell" /root/proxforge-install.sh || rc=$?
  pct exec "$CTID" -- rm -f /root/proxforge-install.sh >/dev/null 2>&1 || true
  return "$rc"
}

# 4. PÉRIPHÉRIQUE TUN
# L'hôte doit exposer /dev/net/tun (module "tun"), et le rendre persistant au redémarrage,
# sinon le bind-mount ferait échouer le démarrage du conteneur.
[[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
[[ -c /dev/net/tun ]] || fail "/dev/net/tun absent sur l'hôte et 'modprobe tun' impossible."
if ! grep -rqs '^tun$' /etc/modules /etc/modules-load.d/ 2>/dev/null; then
  echo "tun" > /etc/modules-load.d/proxforge-tun.conf
  info "Module 'tun' ajouté au chargement automatique de l'hôte (/etc/modules-load.d/proxforge-tun.conf)."
fi

CONFIG_CHANGED=0
info "Configuration des permissions TUN pour le LXC $CTID..."
if ! grep -qF "lxc.cgroup2.devices.allow: c 10:200 rwm" "$CONF"; then
  echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
  CONFIG_CHANGED=1
fi
if ! grep -qF "lxc.mount.entry: /dev/net/tun" "$CONF"; then
  echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CONF"
  CONFIG_CHANGED=1
fi

# 5. DÉMARRAGE SI NÉCESSAIRE
WAS_RUNNING=1
if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
  WAS_RUNNING=0
  info "Démarrage du LXC $CTID..."
  pct start "$CTID" >/dev/null || fail "Démarrage du LXC $CTID échoué."
fi
info "Attente du réseau du conteneur..."
wait_for_network || fail "Le conteneur $CTID n'a pas de connectivité réseau (timeout 60s)."

# 6. INSTALLATION
info "Installation de Tailscale dans le LXC $CTID..."
INSTALL_SCRIPT=$(mktemp)
LOG_FILE=$(mktemp)
TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

# Script POSIX (sh) : le conteneur cible peut être Alpine (ash) ou Debian/Ubuntu (dash)
cat > "$INSTALL_SCRIPT" <<'EOS'
set -eu
if [ -f /etc/alpine-release ]; then
  echo "OS détecté : Alpine Linux."
  # Activation du dépôt community si inactif
  if ! grep -q '^[^#].*community' /etc/apk/repositories 2>/dev/null; then
    ALPINE_VERSION=$(cut -d. -f1,2 /etc/alpine-release)
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
  fi
  apk update
  apk add --no-cache tailscale curl
  rc-update add tailscale default || true
  rc-service tailscale start || true
elif [ -f /etc/debian_version ]; then
  echo "OS détecté : Debian / Ubuntu."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates iptables iproute2
  # Script officiel Tailscale, téléchargé puis exécuté (pas de pipe direct vers sh)
  curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh
  sh /tmp/tailscale-install.sh
  rm -f /tmp/tailscale-install.sh
else
  echo "OS non supporté par ce script (Alpine, Debian et Ubuntu uniquement)." >&2
  exit 1
fi
command -v tailscale >/dev/null 2>&1 || { echo "Commande tailscale introuvable après installation" >&2; exit 1; }
tailscale version
EOS

if ! run_script_in_ct sh "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
  tail -n 30 "$LOG_FILE" >&2
  fail "Installation de Tailscale échouée (le conteneur $CTID n'a pas été supprimé)."
fi

# 7. REDÉMARRAGE (uniquement si le TUN vient d'être ajouté à un conteneur déjà en marche)
NEEDS_REBOOT=0
if (( WAS_RUNNING )) && (( CONFIG_CHANGED )); then
  NEEDS_REBOOT=1
  DO_REBOOT="no"
  if [[ "$AUTO_REBOOT" == "yes" ]]; then
    DO_REBOOT="yes"
  elif [[ -t 0 ]]; then
    read -r -p "Le LXC $CTID tournait déjà : le redémarrer maintenant pour activer le TUN ? [o/N] " ANSWER
    [[ "$ANSWER" =~ ^[oOyY]$ ]] && DO_REBOOT="yes"
  fi
  if [[ "$DO_REBOOT" == "yes" ]]; then
    info "Redémarrage du LXC $CTID..."
    pct reboot "$CTID" >/dev/null || fail "Redémarrage du LXC $CTID échoué."
    NEEDS_REBOOT=0
  fi
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  Tailscale installé sur le LXC $CTID !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
STEP=1
if (( NEEDS_REBOOT )); then
  info "${STEP}. Redémarrez le LXC pour activer le périphérique TUN : pct reboot $CTID"
  STEP=$((STEP + 1))
fi
info "${STEP}. Entrez dans le LXC : pct enter $CTID"
STEP=$((STEP + 1))
info "${STEP}. Connectez-le à votre réseau Tailscale : tailscale up"
echo -e ""
