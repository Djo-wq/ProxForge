#!/usr/bin/env bash
# Script de création automatisée d'un LXC MariaDB (Debian 12) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-mariadb-lxc}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC MariaDB (ID: $CTID)..."

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

# --- 4. DÉMARRAGE ET INSTALLATION DE MARIADB ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation et Configuration de MariaDB (Veuillez patienter)..."
  
  # Injection des commandes d'installation via pct exec
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    
    # 1. Installation de MariaDB Server
    apt-get install -y mariadb-server

    # 2. Configuration du réseau (Écoute sur 0.0.0.0 au lieu de 127.0.0.1)
    # Sur Debian 12, la configuration par défaut se trouve dans 50-server.cnf
    sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
    
    # 3. Redémarrage du service pour appliquer le bind réseau
    systemctl restart mariadb

    # 4. Création de la base de données et de l'utilisateur par défaut
    cat << 'EOF' > /tmp/setup.sql
CREATE DATABASE IF NOT EXISTS proxmox;
CREATE USER IF NOT EXISTS 'proxmox'@'%' IDENTIFIED BY 'Proxmox2026!';
GRANT ALL PRIVILEGES ON proxmox.* TO 'proxmox'@'%';
FLUSH PRIVILEGES;
EOF
    
    # Exécution silencieuse du script SQL
    mariadb < /tmp/setup.sql
    rm -f /tmp/setup.sql
  "
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC MariaDB a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 🐬 Serveur MariaDB joignable sur :\e[0m"
  echo -e "\e[32m Host: ${LXC_IP}\e[0m"
  echo -e "\e[32m Port: 3306\e[0m"
  echo -e ""
  echo -e "\e[33m 🔑 Base de données par défaut configurée :\e[0m"
  echo -e "\e[33m  - Database : proxmox\e[0m"
  echo -e "\e[33m  - User     : proxmox\e[0m"
  echo -e "\e[33m  - Password : Proxmox2026!\e[0m"
  echo -e ""
  echo -e "\e[31m ⚠️ IMPORTANT : Fixez l'IP en statique dans votre routeur.\e[0m"
else
  echo -e "\e[33m MariaDB est installé, cherchez son IP dans l'interface Proxmox.\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
