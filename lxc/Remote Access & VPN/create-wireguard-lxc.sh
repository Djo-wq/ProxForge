#!/usr/bin/env bash
# Script de création automatisée d'un LXC WireGuard + WGDashboard (Debian 12) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-wireguard-lxc}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-512}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="local"

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC WireGuard (ID: $CTID)..."

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

# --- 3. CRÉATION DU CONTENEUR LXC (Avec support TUN activé) ---
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC Debian (Unprivileged + TUN Device)..."

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

# Activation du périphérique TUN (indispensable pour WireGuard)
cat <<EOF >> /etc/pve/lxc/${CTID}.conf
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

# --- 4. DÉMARRAGE ET INSTALLATION DE WIREGUARD & WGDASHBOARD ---
if [ "$START_LXC" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done'

  echo -e "\e[34m[INFO]\e[0m Installation de WireGuard et WGDashboard (Veuillez patienter)..."
  
  # Injection des commandes d'installation via pct exec
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    
    # 1. Installation de WireGuard et des dépendances réseau/Python
    apt-get install -y wireguard-tools iptables iproute2 curl git python3 python3-pip python3-venv procps
    
    # 2. Déploiement de WGDashboard (Interface Web d'administration)
    git clone https://github.com/donaldzou/WGDashboard.git /etc/wgdashboard
    cd /etc/wgdashboard/src
    
    # Création d'un environnement virtuel Python (Obligatoire sur Debian 12 PEP-668)
    python3 -m venv venv
    ./venv/bin/pip install -r requirements.txt
    chmod +x wgd.sh
    
    # 3. Création silencieuse du service systemd (pour éviter les prompts d'installation manuels)
    cat << 'EOF' > /etc/systemd/system/wg-dashboard.service
[Unit]
Description=WGDashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/wgdashboard/src
ExecStart=/etc/wgdashboard/src/venv/bin/python3 dashboard.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now wg-dashboard
  "
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC WireGuard + WGDashboard a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [ -n "$LXC_IP" ]; then
  echo -e "\e[33m 🌐 Accédez à l'interface d'administration WGDashboard :\e[0m"
  echo -e "\e[32m http://${LXC_IP}:10086\e[0m"
  echo -e ""
  echo -e "\e[33m 🔑 Identifiants par défaut :\e[0m"
  echo -e "\e[33m  - Utilisateur : admin\e[0m"
  echo -e "\e[33m  - Mot de passe : admin\e[0m"
  echo -e ""
  echo -e "\e[31m ⚠️ IMPORTANT : Fixez cette IP (${LXC_IP}) en statique\e[0m"
  echo -e "\e[31m dans les baux DHCP de votre routeur.\e[0m"
else
  echo -e "\e[33m WireGuard est installé, cherchez son IP dans Proxmox.\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
