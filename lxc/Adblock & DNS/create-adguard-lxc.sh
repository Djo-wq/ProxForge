#!/usr/bin/env bash
# Script de création automatisée d'un LXC AdGuard Home (Alpine Linux) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-adguard-lxc}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-256}"
DISK_SIZE="${DISK_SIZE:-2G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC AdGuard Home (ID: $CTID)..."

# --- 2. GESTION DU TEMPLATE ALPINE VIA PVEAM ---
echo -e "\e[34m[INFO]\e[0m Mise à jour de la liste des templates Proxmox..."
pveam update >/dev/null

echo -e "\e[34m[INFO]\e[0m Recherche du dernier template Alpine Linux..."
TEMPLATE_NAME=$(pveam available -section system | grep "alpine-" | sort -V | tail -n 1 | awk '{print $2}')

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le template Alpine sur les serveurs Proxmox."
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
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC Alpine (Unprivileged)..."

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype alpine \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --unprivileged 1

# --- 4. DÉMARRAGE ET INSTALLATION DE ADGUARD HOME ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- ash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation de AdGuard Home (Veuillez patienter)..."
  pct exec "$CTID" -- ash -c "
    apk update
    apk upgrade
    apk add curl tar gzip wget

    # Téléchargement et installation d'AdGuard Home
    wget -qO adguardhome.tar.gz https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
    tar -xzf adguardhome.tar.gz
    mv AdGuardHome /opt/AdGuardHome
    rm adguardhome.tar.gz

    # Installation comme service
    /opt/AdGuardHome/AdGuardHome -s install

    # Démarrage du service
    rc-service adguardhome start
    rc-update add adguardhome default
  "
fi

# Récupération de l'IP DHCP
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC AdGuard Home a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m Accédez à l'interface de configuration initiale ici :\e[0m"
  echo -e "\e[32m http://${LXC_IP}:3000\e[0m"
else
  echo -e "\e[33m Votre environnement AdGuard Home est prêt.\e[0m"
  echo -e "\e[33m Cherchez son IP dans l'interface Proxmox (port 3000).\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
