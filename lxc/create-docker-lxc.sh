#!/usr/bin/env bash
# Script de création automatisée d'un LXC Docker (Debian 12) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-docker-lxc}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"     # 8G minimum recommandé pour Docker
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"         # Stockage où sont téléchargés les templates LXC

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC Docker (ID: $CTID)..."

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
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC (Unprivileged + Nesting)..."

# L'option "nesting=1" et "keyctl=1" sont OBLIGATOIRES pour faire tourner Docker dans un LXC
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype debian \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1

# --- 4. DÉMARRAGE ET INSTALLATION DE DOCKER ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  # Boucle pour s'assurer que le LXC a bien accès à Internet avant de lancer l'installation
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation de Docker et Docker-Compose (Veuillez patienter)..."
  # Injection des commandes à l'intérieur du conteneur LXC via "pct exec"
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl ca-certificates gnupg
    
    # Installation officielle de Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    
    # Installation du plugin Compose
    apt-get install -y docker-compose-plugin
    
    # Activation du service
    systemctl enable --now docker
  "
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC Docker a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
echo -e "\e[33m Votre environnement Docker est prêt à l'emploi.\e[0m"
echo -e "\e[33m Pour vous y connecter depuis l'hôte Proxmox, tapez :\e[0m"
echo -e "\e[33m pct enter $CTID\e[0m"
echo -e "\e[33m====================================================\e[0m"
