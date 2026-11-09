#!/usr/bin/env bash
# ProxForge — AdGuard Home (Alpine) pour Proxmox VE 9.2
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
HN="${HN:-adguard-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-256}"
DISK_SIZE="${DISK_SIZE:-2G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

[[ "$CTID" =~ ^[0-9]+$ ]]          || fail "CTID invalide : '$CTID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '2G' (en Go uniquement)."
pvesh get /cluster/nextid --vmid "$CTID" >/dev/null 2>&1 || fail "L'ID $CTID est déjà utilisé."

# Proxmox attend une taille en Go sans unité pour créer un volume (STOCKAGE:2, pas STOCKAGE:2G).
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

TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "alpine-" | sort -V | tail -n 1 | awk '{print $2}' || true)
[[ -n "$TEMPLATE_NAME" ]] || fail "Template Alpine introuvable."

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -F "vztmpl/${TEMPLATE_FILE}" >/dev/null; then
  ok "Template déjà présent en cache : $TEMPLATE_FILE"
else
  info "Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || fail "Téléchargement du template échoué."
fi

# 5. CRÉATION LXC
info "Création du conteneur LXC AdGuard Home (Unprivileged)..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype alpine \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --unprivileged 1 \
  --onboot 1 \
  --description "AdGuard Home - ProxForge" >/dev/null || fail "Création du conteneur échouée."
CT_CREATED=1

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  info "Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || fail "Démarrage du conteneur échoué."

  info "Attente du réseau (DHCP)..."
  wait_for_network || fail "Timeout DHCP après 60s."

  info "Installation d'AdGuard Home (veuillez patienter)..."
  INSTALL_SCRIPT=$(mktemp)
  LOG_FILE=$(mktemp)
  TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

  # Alpine : ash (busybox), donc pas de "pipefail" ici.
  cat > "$INSTALL_SCRIPT" <<'EOS'
set -eu
apk update
apk upgrade
apk add --no-cache curl tar gzip wget ca-certificates

cd /tmp
wget -q -O adguardhome.tar.gz https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar -xzf adguardhome.tar.gz
rm -rf /opt/AdGuardHome
mv AdGuardHome /opt/AdGuardHome
rm -f adguardhome.tar.gz

# Installe le service OpenRC puis le démarre.
/opt/AdGuardHome/AdGuardHome -s install

# Le nom du script OpenRC dépend de la version (casse) : on le détecte au lieu de le supposer.
SVC=$(find /etc/init.d -maxdepth 1 -iname 'adguardhome' -print -quit)
[ -n "$SVC" ] || { echo "Service OpenRC AdGuard Home introuvable dans /etc/init.d" >&2; exit 1; }
SVC=$(basename "$SVC")
rc-update add "$SVC" default
rc-service "$SVC" start || /opt/AdGuardHome/AdGuardHome -s start
EOS

  if ! run_script_in_ct ash "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
    tail -n 30 "$LOG_FILE" >&2
    fail "Installation d'AdGuard Home échouée."
  fi
fi

# 7. RÉSULTAT
LXC_IP=""
if [[ "$START_LXC" == "yes" ]]; then
  LXC_IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}' || true)
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC AdGuard Home déployé avec succès (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
if [[ -n "$LXC_IP" ]]; then
  info "Assistant de configuration : http://${LXC_IP}:3000"
  info "Après l'assistant, l'interface passe sur le port que vous aurez choisi (80 par défaut)."
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
elif [[ "$START_LXC" == "yes" ]]; then
  warn "IP introuvable : cherchez-la dans l'interface Proxmox (port 3000)."
else
  info "Conteneur non démarré : pct start $CTID, puis installez AdGuard Home (START_LXC=yes pour automatiser)."
fi
echo -e ""
