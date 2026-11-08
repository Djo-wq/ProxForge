#!/usr/bin/env bash
# ProxForge — MongoDB (Debian 12) pour Proxmox VE 9.2
set -euo pipefail

# 1. VALIDATIONS
[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in pct pveam pvesh; do 
  command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }
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

# 3. CLEANUP
CT_CREATED=0
cleanup() {
  local exit_code=$?
  if (( exit_code != 0 )) && (( CT_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression du conteneur $CTID..." >&2
    pct stop "$CTID" >/dev/null 2>&1 || true
    pct destroy "$CTID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT ERR

# 4. TEMPLATE
echo -e "\e[34m[INFO]\e[0m Mise à jour des templates..."
pveam update >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m pveam update échoué" >&2; exit 1; }
TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}')
[[ -z "$TEMPLATE_NAME" ]] && { echo -e "\e[31m[ERREUR]\e[0m Template introuvable" >&2; exit 1; }
TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
if [[ ! -f "/var/lib/vz/template/cache/${TEMPLATE_FILE}" ]]; then
  echo -e "\e[34m[INFO]\e[0m Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Téléchargement échoué" >&2; exit 1; }
else
  echo -e "\e[32m[OK]\e[0m Template déjà présent en cache : $TEMPLATE_FILE"
fi

# 5. CRÉATION LXC
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC MongoDB (Unprivileged)..."
pct create "$CTID" \
  "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype debian \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --unprivileged 1 \
  --description "MongoDB - ProxForge" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Création échouée" >&2; exit 1; }
CT_CREATED=1

# 6. INSTALLATION
if [[ "$START_LXC" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Démarrage échoué" >&2; exit 1; }
  
  echo -e "\e[34m[INFO]\e[0m Attente IP DHCP..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done' || { 
    echo -e "\e[31m[ERREUR]\e[0m Timeout DHCP après 60s" >&2
    exit 1 
  }

  echo -e "\e[34m[INFO]\e[0m Installation et Configuration de MongoDB (Veuillez patienter)..."
  pct exec "$CTID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl gnupg

    # 1. Ajout de la clé GPG et du dépôt officiel MongoDB (version 7.0 stable pour Debian 12)
    curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" > /etc/apt/sources.list.d/mongodb-org-7.0.list
    
    # 2. Installation de MongoDB
    apt-get update -y
    apt-get install -y mongodb-org
    
    # 3. Configuration du réseau (Écoute sur toutes les interfaces 0.0.0.0 au lieu de 127.0.0.1)
    sed -i "s/bindIp: 127.0.0.1/bindIp: 0.0.0.0/" /etc/mongod.conf
    
    # 4. Démarrage de MongoDB
    systemctl enable --now mongod
    
    # Attente que le service soit prêt pour accepter des requêtes
    sleep 5
    
    # 5. Création de l"utilisateur Administrateur
    mongosh admin --eval "db.createUser({user: \"proxmox\", pwd: \"Proxmox2026!\", roles: [{role: \"root\", db: \"admin\"}]})"
    
    # 6. Activation de l"authentification dans mongod.conf
    sed -i "s/#security:/security:\n  authorization: enabled/" /etc/mongod.conf
    
    # Redémarrage final pour appliquer la sécurité
    systemctl restart mongod
  ' >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Installation échouée" >&2; exit 1; }
fi

# 7. RÉSULTAT
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")

echo -e "\n\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC MongoDB déployé avec succès (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
if [[ -n "$LXC_IP" ]]; then
  echo -e "\e[36m[INFO]\e[0m Interface : MongoDB sur ${LXC_IP}:27017"
  echo -e "\e[36m[INFO]\e[0m Auth DB   : admin"
  echo -e "\e[36m[INFO]\e[0m User      : proxmox"
  echo -e "\e[36m[INFO]\e[0m Password  : Proxmox2026!"
  echo -e "\e[31m[⚠️]\e[0m Fixez l'IP ${LXC_IP} en statique dans votre routeur."
else
  echo -e "\e[33m[AVERTISSEMENT]\e[0m Cherchez l'IP dans l'interface Proxmox."
fi
echo -e ""
