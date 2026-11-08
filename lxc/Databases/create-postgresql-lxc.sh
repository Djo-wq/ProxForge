#!/usr/bin/env bash
# Script de création automatisée d'un LXC PostgreSQL (Debian 12) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-postgresql-lxc}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC PostgreSQL (ID: $CTID)..."

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

# --- 4. DÉMARRAGE ET INSTALLATION DE POSTGRESQL ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation et Configuration de PostgreSQL (Veuillez patienter)..."
  
  # Injection des commandes d'installation via pct exec
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y postgresql postgresql-contrib

    # --- Configuration du réseau PostgreSQL ---
    # Autoriser l'écoute sur toutes les interfaces (0.0.0.0) au lieu de localhost
    sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf
    
    # Autoriser les connexions externes via mot de passe (scram-sha-256)
    echo 'host    all             all             0.0.0.0/0               scram-sha-256' >> /etc/postgresql/*/main/pg_hba.conf

    # Redémarrage du service pour appliquer la configuration réseau
    systemctl restart postgresql

    # --- Création de l'utilisateur et de la base par défaut ---
    cat << 'EOF' > /tmp/setup.sql
CREATE USER proxmox WITH PASSWORD 'Proxmox2026!';
CREATE DATABASE proxmox OWNER proxmox;
EOF
    
    # Exécution du script SQL en tant qu'utilisateur postgres (superadmin par défaut)
    su - postgres -c 'psql -f /tmp/setup.sql'
    rm -f /tmp/setup.sql
  "
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC PostgreSQL a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 🗄️ Serveur PostgreSQL joignable sur :\e[0m"
  echo -e "\e[32m Host: ${LXC_IP}\e[0m"
  echo -e "\e[32m Port: 5432\e[0m"
  echo -e ""
  echo -e "\e[33m 🔑 Base de données par défaut configurée :\e[0m"
  echo -e "\e[33m  - Database : proxmox\e[0m"
  echo -e "\e[33m  - User     : proxmox\e[0m"
  echo -e "\e[33m  - Password : Proxmox2026!\e[0m"
  echo -e ""
  echo -e "\e[31m ⚠️ IMPORTANT : Fixez l'IP en statique dans votre routeur.\e[0m"
else
  echo -e "\e[33m PostgreSQL est installé, cherchez son IP dans l'interface Proxmox.\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
