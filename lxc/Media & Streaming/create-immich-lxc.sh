#!/usr/bin/env bash
# Script de création automatisée d'un LXC Immich (Debian 13 Trixie / Debian Testing) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-immich-lxc}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-6144}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC Immich (ID: $CTID)..."

# --- 2. GESTION DU TEMPLATE DEBIAN VIA PVEAM ---
echo -e "\e[34m[INFO]\e[0m Mise à jour de la liste des templates Proxmox..."
pveam update >/dev/null

echo -e "\e[34m[INFO]\e[0m Recherche du dernier template Debian 12 (Bookworm)..."
# Proxmox ne propose pas nativement de template 'Trixie', on déploie Bookworm puis on fera un dist-upgrade
TEMPLATE_NAME=$(pveam available -section system | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}')

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le template Debian sur les serveurs Proxmox."
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
  --features nesting=1 \
  --unprivileged 1

# --- CONFIGURATION GPU PASSTHROUGH (Transcodage Matériel Intel/AMD) ---
if [ -c /dev/dri/renderD128 ]; then
  echo -e "\e[34m[INFO]\e[0m GPU détecté sur l'hôte. Configuration du passthrough matériel..."
  cat <<EOF >> /etc/pve/lxc/${CTID}.conf
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
else
  echo -e "\e[33m[NOTE]\e[0m Aucun GPU détecté (/dev/dri/renderD128 absent)."
fi

# --- 4. DÉMARRAGE ET INSTALLATION D'IMMICH ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m L'installation d'Immich en mode natif (sans Docker) est extrêmement complexe."
  echo -e "\e[34m[INFO]\e[0m Elle requiert la compilation depuis les sources de dizaines de librairies (libjxl, libvips...)."
  echo -e "\e[34m[INFO]\e[0m Pour ce déploiement, nous allons injecter l'installateur officiel Docker (Recommandé par Immich)."
  echo -e "\e[34m[INFO]\e[0m Mise à niveau vers Debian 13 (Testing/Trixie) et installation de Docker..."

  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    
    # Upgrade vers Trixie (Debian 13) car requis par les librairies Immich
    sed -i 's/bookworm/trixie/g' /etc/apt/sources.list.d/debian.sources
    apt-get update -y
    apt-get dist-upgrade -y
    
    # Installation de Docker
    apt-get install -y curl ca-certificates git
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    
    # Déploiement de la stack Immich officielle
    mkdir -p /opt/immich
    cd /opt/immich
    curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
    curl -fsSL -o example.env https://github.com/immich-app/immich/releases/latest/download/example.env
    cp example.env .env
    
    # Modification du dossier d'upload par défaut
    sed -i 's/UPLOAD_LOCATION=.\/library/UPLOAD_LOCATION=\/opt\/immich\/library/' .env
    
    # Démarrage de la stack
    docker compose up -d
  "
fi

LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC Immich a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 📸 Accédez à l'interface d'Immich :\e[0m"
  echo -e "\e[32m http://${LXC_IP}:2283\e[0m"
  echo -e ""
  echo -e "\e[31m ⚠️ IMPORTANT : Fixez cette IP (${LXC_IP}) en statique.\e[0m"
else
  echo -e "\e[33m Immich est installé, cherchez son IP dans Proxmox.\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
