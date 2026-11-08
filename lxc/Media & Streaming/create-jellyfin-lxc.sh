#!/usr/bin/env bash
# Script de création automatisée d'un LXC Jellyfin (Ubuntu 24.04) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-jellyfin-lxc}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-16G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC Jellyfin (ID: $CTID)..."

# --- 2. GESTION DU TEMPLATE UBUNTU VIA PVEAM ---
echo -e "\e[34m[INFO]\e[0m Mise à jour de la liste des templates Proxmox..."
pveam update >/dev/null

echo -e "\e[34m[INFO]\e[0m Recherche du dernier template Ubuntu 24.04 (Noble)..."
TEMPLATE_NAME=$(pveam available -section system | grep "ubuntu-24.04-standard" | sort -V | tail -n 1 | awk '{print $2}')

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le template Ubuntu 24.04 sur les serveurs Proxmox."
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
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC Ubuntu (Unprivileged)..."

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype ubuntu \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --features nesting=1 \
  --unprivileged 1

# --- CONFIGURATION GPU PASSTHROUGH (Transcodage Matériel Intel/AMD) ---
if [ -c /dev/dri/renderD128 ]; then
  echo -e "\e[34m[INFO]\e[0m GPU détecté sur l'hôte. Configuration du passthrough matériel pour le transcodage..."
  cat <<EOF >> /etc/pve/lxc/${CTID}.conf
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
else
  echo -e "\e[33m[NOTE]\e[0m Aucun GPU détecté (/dev/dri/renderD128 absent). Le transcodage sera 100% logiciel (CPU)."
fi

# --- 4. DÉMARRAGE ET INSTALLATION DE JELLYFIN ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation de Jellyfin et ses dépendances (Veuillez patienter)..."
  
  # Injection des commandes d'installation via l'API APT Jellyfin officielle
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl gnupg ca-certificates apt-transport-https

    # 1. Ajout de la clé GPG Jellyfin
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg

    # 2. Ajout du dépôt APT
    cat << 'EOF' > /etc/apt/sources.list.d/jellyfin.sources
Types: deb
URIs: https://repo.jellyfin.org/ubuntu
Suites: noble
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF

    # 3. Installation de Jellyfin, de FFMPEG spécifique et du gestionnaire de RAM (jemalloc)
    apt-get update -y
    apt-get install -y jellyfin jellyfin-ffmpeg8 libjemalloc2

    # 4. Optimisation de la mémoire (jemalloc)
    if [[ ! -f /usr/lib/libjemalloc.so ]]; then
      ln -sf /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/libjemalloc.so
    fi

    # 5. Démarrage du service
    systemctl enable --now jellyfin
  "
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC Jellyfin a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 🍿 Accédez à votre nouveau serveur multimédia :\e[0m"
  echo -e "\e[32m http://${LXC_IP}:8096\e[0m"
else
  echo -e "\e[33m Jellyfin est installé, cherchez son IP dans l'interface Proxmox (port 8096).\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
