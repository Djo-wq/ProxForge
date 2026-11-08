#!/usr/bin/env bash
# Script de création automatisée d'un LXC PowerDNS & Poweradmin (Debian 12) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-powerdns-lxc}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC PowerDNS (ID: $CTID)..."

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

# --- 4. DÉMARRAGE ET INSTALLATION DE POWERDNS & POWERADMIN ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation de PowerDNS et Apache/PHP (Veuillez patienter)..."
  
  # Injection des commandes d'installation via pct exec
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    
    # 1. Installation de PowerDNS (avec backend SQLite3)
    apt-get install -y pdns-server pdns-backend-sqlite3 sqlite3
    
    # 2. Installation de la stack web pour Poweradmin
    apt-get install -y apache2 php libapache2-mod-php php-sqlite3 gettext git
    
    # 3. Configuration de la base de données PowerDNS
    mkdir -p /var/lib/powerdns
    sqlite3 /var/lib/powerdns/powerdns.db < /usr/share/doc/pdns-backend-sqlite3/schema.sqlite3.sql
    chown pdns:pdns /var/lib/powerdns/powerdns.db
    chmod 664 /var/lib/powerdns/powerdns.db
    
    # 4. Configuration de PowerDNS pour utiliser la BDD SQLite
    cat << 'EOF' > /etc/powerdns/pdns.d/gsqlite3.conf
launch=gsqlite3
gsqlite3-database=/var/lib/powerdns/powerdns.db
EOF
    systemctl restart pdns
    
    # 5. Déploiement de Poweradmin (Interface Web)
    rm -rf /var/www/html/*
    git clone https://github.com/poweradmin/poweradmin.git /opt/poweradmin
    cp -r /opt/poweradmin/* /var/www/html/
    
    # 6. Configuration de Poweradmin
    cat << 'EOF' > /var/www/html/config/settings.php
<?php
\$db_host = '';
\$db_user = '';
\$db_pass = '';
\$db_name = '/var/lib/powerdns/powerdns.db';
\$db_type = 'sqlite3';
\$session_key = '$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20)';
EOF
    
    # Sécurisation des permissions
    chown -R www-data:www-data /var/www/html/
    chmod -R 775 /var/www/html/
    usermod -aG pdns www-data
    
    # Suppression du dossier d'installation de Poweradmin par sécurité
    rm -rf /var/www/html/install
    
    # 7. Redémarrage d'Apache
    systemctl restart apache2
  "
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC PowerDNS & Poweradmin a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 🌐 Accédez à l'interface d'administration Poweradmin :\e[0m"
  echo -e "\e[32m http://${LXC_IP}\e[0m"
  echo -e "\e[33m 🔑 Identifiant par défaut : admin\e[0m"
  echo -e "\e[33m 🔑 Mot de passe par défaut : admin\e[0m"
  echo -e ""
  echo -e "\e[31m ⚠️ IMPORTANT : Fixez cette IP (${LXC_IP}) en statique\e[0m"
  echo -e "\e[31m dans les baux DHCP de votre routeur.\e[0m"
else
  echo -e "\e[33m PowerDNS est installé, cherchez son IP dans l'interface Proxmox.\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
