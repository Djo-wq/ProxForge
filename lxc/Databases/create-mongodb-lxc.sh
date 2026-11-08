#!/usr/bin/env bash
# Script de création automatisée d'un LXC MongoDB (Debian 12) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-mongodb-lxc}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}" # 1024 Mo recommandé pour MongoDB (gourmand en RAM)
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC MongoDB (ID: $CTID)..."

# --- 2. GESTION DU TEMPLATE DEBIAN VIA PVEAM ---
echo -e "\e[34m[INFO]\e[0m Mise à jour de la liste des templates Proxmox..."
pveam update >/dev/null

echo -e "\e[34m[INFO]\e[0m Recherche du dernier template Debian 12 (Bookworm)..."
TEMPLATE_NAME=$(pveam available -section system | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}')

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le template Debian 12 sur les serveurs Proxmox."
  exit 1
fi

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
CACHE_PATH="/var/lib/vz/template/cache/${TEMPLATE_FILE}"

if [ -f "$CACHE_PATH" ]; then
  echo -e "\e[32m[OK]\e[0m Template déjà présent en cache : $TEMPLATE_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement du template ${TEMPLATE_FILE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi

# --- 3. CRÉATION DU CONTENEUR LXC ---
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC Debian (Unprivileged)..."

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype debian \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --unprivileged 1

# --- 4. DÉMARRAGE ET INSTALLATION DE MONGODB ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation et Configuration de MongoDB (Veuillez patienter)..."
  
  # Injection des commandes d'installation via pct exec
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl gnupg

    # 1. Ajout de la clé GPG et du dépôt officiel MongoDB (version 7.0 stable pour Debian 12)
    curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo 'deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main' > /etc/apt/sources.list.d/mongodb-org-7.0.list
    
    # 2. Installation de MongoDB
    apt-get update -y
    apt-get install -y mongodb-org
    
    # 3. Configuration du réseau (Écoute sur toutes les interfaces 0.0.0.0 au lieu de 127.0.0.1)
    sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
    
    # 4. Démarrage de MongoDB
    systemctl enable --now mongod
    
    # Attente que le service soit prêt pour accepter des requêtes
    sleep 5
    
    # 5. Création de l'utilisateur Administrateur
    mongosh admin --eval "db.createUser({user: 'proxmox', pwd: 'Proxmox2026!', roles: [{role: 'root', db: 'admin'}]})"
    
    # 6. Activation de l'authentification dans mongod.conf
    sed -i 's/#security:/security:\n  authorization: enabled/' /etc/mongod.conf
    
    # Redémarrage final pour appliquer la sécurité
    systemctl restart mongod
  "
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC MongoDB a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 🍃 Serveur MongoDB joignable sur :\e[0m"
  echo -e "\e[32m Host: ${LXC_IP}\e[0m"
  echo -e "\e[32m Port: 27017\e[0m"
  echo -e ""
  echo -e "\e[33m 🔑 Identifiants d'administration (Root) :\e[0m"
  echo -e "\e[33m  - Auth DB  : admin\e[0m"
  echo -e "\e[33m  - User     : proxmox\e[0m"
  echo -e "\e[33m  - Password : Proxmox2026!\e[0m"
  echo -e ""
  echo -e "\e[31m ⚠️ IMPORTANT : Fixez l'IP en statique dans votre routeur.\e[0m"
else
  echo -e "\e[33m MongoDB est installé, cherchez son IP dans l'interface Proxmox.\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
