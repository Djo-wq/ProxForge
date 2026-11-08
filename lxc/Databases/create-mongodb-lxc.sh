#!/usr/bin/env bash
# ProxForge — MongoDB (Debian 12) pour Proxmox VE 9.2
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
HN="${HN:-mongodb-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
MONGO_VERSION="${MONGO_VERSION:-7.0}"
DB_USER="${DB_USER:-proxmox}"
DB_PASSWORD="${DB_PASSWORD:-}"

ID_RE='^[A-Za-z_][A-Za-z0-9_]*$'
PW_RE='^[A-Za-z0-9_.@#%^*+=-]{8,}$'
VER_RE='^[0-9]+\.[0-9]+$'

[[ "$CTID" =~ ^[0-9]+$ ]]          || fail "CTID invalide : '$CTID'."
[[ "$CPU_CORES" =~ ^[0-9]+$ ]]     || fail "CPU_CORES doit être un entier."
[[ "$RAM_SIZE" =~ ^[0-9]+$ ]]      || fail "RAM_SIZE doit être un entier (en Mo)."
[[ "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]] || fail "DISK_SIZE doit être au format '4G' (en Go uniquement)."
[[ "$MONGO_VERSION" =~ $VER_RE ]]  || fail "MONGO_VERSION doit être du type '7.0'."
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
info "Création du conteneur LXC MongoDB (Unprivileged)..."
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
  --description "MongoDB ${MONGO_VERSION} - ProxForge" >/dev/null || fail "Création du conteneur échouée."
CT_CREATED=1

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  info "Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || fail "Démarrage du conteneur échoué."

  info "Attente du réseau (DHCP)..."
  wait_for_network || fail "Timeout DHCP après 60s."

  info "Installation et configuration de MongoDB ${MONGO_VERSION} (veuillez patienter)..."
  INSTALL_SCRIPT=$(mktemp)   # mktemp crée le fichier en 0600 : il contient le mot de passe
  LOG_FILE=$(mktemp)
  TMP_FILES+=("$INSTALL_SCRIPT" "$LOG_FILE")

  {
    printf 'MONGO_VERSION=%q\nDB_USER=%q\nDB_PASSWORD=%q\n' "$MONGO_VERSION" "$DB_USER" "$DB_PASSWORD"
    cat <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl gnupg ca-certificates

# Clé GPG et dépôt officiels MongoDB (Debian 12 "bookworm")
KEYRING="/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"
curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" | gpg --batch --yes --dearmor -o "$KEYRING"
[ -s "$KEYRING" ] || { echo "Clé GPG MongoDB ${MONGO_VERSION} introuvable" >&2; exit 1; }
echo "deb [ signed-by=${KEYRING} ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/${MONGO_VERSION} main" \
  > "/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"

apt-get update -y
apt-get install -y mongodb-org

# 1. Démarrage en local uniquement (127.0.0.1, sans authentification) pour créer l'administrateur
systemctl enable --now mongod
for _ in $(seq 1 30); do
  mongosh --quiet --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1 && break
  sleep 1
done
mongosh --quiet --eval 'db.runCommand({ping: 1}).ok' >/dev/null

# Identifiants passés par l'environnement (pas de mot de passe interpolé dans le JavaScript)
DB_USER="$DB_USER" DB_PASSWORD="$DB_PASSWORD" mongosh --quiet admin --eval \
  'db.createUser({user: process.env.DB_USER, pwd: process.env.DB_PASSWORD, roles: [{role: "root", db: "admin"}]})' >/dev/null

# 2. Seulement ensuite : écoute réseau + authentification obligatoire
sed -i 's/^\([[:space:]]*\)bindIp:.*/\1bindIp: 0.0.0.0/' /etc/mongod.conf
grep -q '^[[:space:]]*bindIp: 0.0.0.0' /etc/mongod.conf
if grep -q '^security:' /etc/mongod.conf; then
  echo "Section 'security' déjà présente dans mongod.conf : vérifiez-la manuellement" >&2
  exit 1
fi
printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
systemctl restart mongod

# 3. Vérification : connexion authentifiée
for _ in $(seq 1 30); do
  mongosh --quiet -u "$DB_USER" -p "$DB_PASSWORD" --authenticationDatabase admin --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1 && break
  sleep 1
done
mongosh --quiet -u "$DB_USER" -p "$DB_PASSWORD" --authenticationDatabase admin --eval 'db.runCommand({ping: 1}).ok' >/dev/null
EOS
  } > "$INSTALL_SCRIPT"

  if ! run_script_in_ct bash "$INSTALL_SCRIPT" >"$LOG_FILE" 2>&1; then
    tail -n 30 "$LOG_FILE" >&2
    fail "Installation de MongoDB échouée."
  fi
fi

# 7. RÉSULTAT
LXC_IP=""
if [[ "$START_LXC" == "yes" ]]; then
  LXC_IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}' || true)
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC MongoDB déployé avec succès (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
if [[ -n "$LXC_IP" ]]; then
  info "Serveur : ${LXC_IP}:27017"
  info "Base d'authentification : admin"
  info "Compte  : ${DB_USER} (rôle root)"
  if (( PW_GENERATED )); then
    echo -e "\e[33m[IMPORTANT]\e[0m Mot de passe généré : ${DB_PASSWORD}  (notez-le)"
  else
    info "Mot de passe : celui fourni via DB_PASSWORD"
  fi
  warn "MongoDB accepte les connexions de toutes les adresses : limitez l'accès (pare-feu Proxmox)."
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
elif [[ "$START_LXC" == "yes" ]]; then
  warn "IP introuvable : cherchez-la dans l'interface Proxmox ou avec : pct exec $CTID -- ip a"
else
  info "Conteneur non démarré : pct start $CTID, puis installez MongoDB (START_LXC=yes pour automatiser)."
fi
echo -e ""
