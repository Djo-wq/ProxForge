#!/usr/bin/env bash
# ProxForge — MariaDB (Debian 12) pour Proxmox VE 9.2
set -euo pipefail

info() { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[AVERTISSEMENT]\e[0m $*" >&2; }
fail() { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }

gen_password() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

# 1. VALIDATIONS
[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root."
for cmd in pct pveam pvesh awk base64; do
  command -v "$cmd" >/dev/null 2>&1 || fail "La commande '$cmd' est requise mais introuvable."
done

# 2. CONFIGURATION
CTID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-mariadb-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DB_NAME="${DB_NAME:-proxmox}"
DB_USER="${DB_USER:-proxmox}"
DB_PASSWORD="${DB_PASSWORD:-}"

ID_RE='^[A-Za-z_][A-Za-z0-9_]*$'
PW_RE='^[A-Za-z0-9_.@#%^*+=-]{8,}$'

[[ "$CTID" =~ ^[0-9]+$ ]]          || fail "CTID invalide : '$CTID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '4G' (en Go uniquement)."
[[ "$DB_NAME" =~ $ID_RE ]]         || fail "DB_NAME invalide (lettres, chiffres et _ uniquement)."
[[ "$DB_USER" =~ $ID_RE ]]         || fail "DB_USER invalide (lettres, chiffres et _ uniquement)."
pvesh get /cluster/nextid --vmid "$CTID" >/dev/null 2>&1 || fail "L'ID $CTID est déjà utilisé."

# Proxmox attend une taille en Go sans unité pour créer un volume (STOCKAGE:4, pas STOCKAGE:4G).
DISK_GB="${DISK_SIZE%[Gg]}"

# Mot de passe : fourni, ou généré (jamais de mot de passe par défaut public : la base écoute sur le réseau).
PW_GENERATED=0
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD=$(gen_password)
  PW_GENERATED=1
elif [[ ! "$DB_PASSWORD" =~ $PW_RE ]]; then
  fail "DB_PASSWORD : 8 caractères minimum parmi A-Z a-z 0-9 _ . @ # % ^ * + = - (ni espace, ni guillemet, ni \$, ni \\)."
fi

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

TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}' || true)
[[ -n "$TEMPLATE_NAME" ]] || fail "Template Debian 12 introuvable."

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -F "vztmpl/${TEMPLATE_FILE}" >/dev/null; then
  ok "Template déjà présent en cache : $TEMPLATE_FILE"
else
  info "Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || fail "Téléchargement du template échoué."
fi

# 5. CRÉATION LXC
info "Création du conteneur LXC MariaDB (Unprivileged)..."
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
  --description "MariaDB - ProxForge" >/dev/null || fail "Création du conteneur échouée."
CT_CREATED=1

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  info "Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || fail "Démarrage du conteneur échoué."

  info "Attente du réseau (DHCP)..."
  wait_for_network || fail "Timeout DHCP après 60s."

  info "Installation et configuration de MariaDB (veuillez patienter)..."
  INSTALL_SCRIPT=$(mktemp)   # mktemp crée le fichier en 0600 : il contient le mot de passe
  LOG_FILE=$(mktemp)
  TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

  {
    printf 'DB_NAME=%q\nDB_USER=%q\nDB_PASSWORD=%q\n' "$DB_NAME" "$DB_USER" "$DB_PASSWORD"
    cat <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y mariadb-server

# Écoute réseau via un fichier dédié (chargé après 50-server.cnf, donc prioritaire) plutôt qu'un sed
cat > /etc/mysql/mariadb.conf.d/99-proxforge.cnf <<'CNF'
[mysqld]
bind-address = 0.0.0.0
CNF

systemctl enable mariadb
systemctl restart mariadb
for _ in $(seq 1 30); do
  mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done
mariadb -e 'SELECT 1' >/dev/null

# Le compte root reste en authentification par socket Unix (local uniquement)
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
EOS
  } > "$INSTALL_SCRIPT"

  if ! run_script_in_ct bash "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
    tail -n 30 "$LOG_FILE" >&2
    fail "Installation de MariaDB échouée."
  fi
fi

# 7. RÉSULTAT
LXC_IP=""
if [[ "$START_LXC" == "yes" ]]; then
  LXC_IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}' || true)
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC MariaDB déployé avec succès (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
if [[ -n "$LXC_IP" ]]; then
  info "Serveur : ${LXC_IP}:3306"
  info "Base    : ${DB_NAME}"
  info "Compte  : ${DB_USER}"
  if (( PW_GENERATED )); then
    echo -e "\e[33m[IMPORTANT]\e[0m Mot de passe généré : ${DB_PASSWORD}  (notez-le)"
  else
    info "Mot de passe : celui fourni via DB_PASSWORD"
  fi
  warn "MariaDB accepte les connexions de toutes les adresses : limitez l'accès (pare-feu Proxmox)."
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
elif [[ "$START_LXC" == "yes" ]]; then
  warn "IP introuvable : cherchez-la dans l'interface Proxmox ou avec : pct exec $CTID -- ip a"
else
  info "Conteneur non démarré : pct start $CTID, puis installez MariaDB (START_LXC=yes pour automatiser)."
fi
echo -e ""
