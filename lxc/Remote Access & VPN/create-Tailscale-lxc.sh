#!/usr/bin/env bash
# Script pour installer et configurer Tailscale sur un LXC existant dans Proxmox VE
set -euo pipefail

echo -e "\e[34m[INFO]\e[0m Lancement de l'ajout de Tailscale sur un LXC existant."

# Demande du CTID à l'utilisateur
read -p "Entrez l'ID du conteneur LXC (CTID) sur lequel installer Tailscale : " CTID

if ! pct status "$CTID" >/dev/null 2>&1; then
    echo -e "\e[31m[ERREUR]\e[0m Le LXC $CTID n'existe pas."
    exit 1
fi

CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"

echo -e "\e[34m[INFO]\e[0m Configuration des permissions TUN pour le LXC $CTID..."
# Ajouter les permissions pour le périphérique TUN si elles ne sont pas déjà présentes
if ! grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$CTID_CONFIG_PATH"; then
    echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CTID_CONFIG_PATH"
fi
if ! grep -q "lxc.mount.entry: /dev/net/tun" "$CTID_CONFIG_PATH"; then
    echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CTID_CONFIG_PATH"
fi

# Démarrage du conteneur s'il est éteint
if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du LXC $CTID..."
  pct start "$CTID"
  sleep 5
fi

echo -e "\e[34m[INFO]\e[0m Installation de Tailscale dans le LXC $CTID..."

# Injection du script d'installation dans le LXC
pct exec "$CTID" -- bash -c '
set -euo pipefail

# Detection du systeme d exploitation
if [ -f /etc/alpine-release ]; then
    echo -e "\e[34m[INFO]\e[0m OS detecte : Alpine Linux."
    # Activation du depot community si inactif
    if ! grep -q "^[^#].*community" /etc/apk/repositories 2>/dev/null; then
        ALPINE_VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
        echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
    fi
    apk update
    apk add --no-cache tailscale curl
    rc-update add tailscale default 2>/dev/null || true
    rc-service tailscale start 2>/dev/null || true
elif [ -f /etc/debian_version ]; then
    echo -e "\e[34m[INFO]\e[0m OS detecte : Debian / Ubuntu."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates iptables iproute2
    
    # Execution du script officiel Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo -e "\e[31m[ERREUR]\e[0m OS non supporte par ce script (Alpine, Debian et Ubuntu uniquement)."
    exit 1
fi
'

echo -e "\n\e[32m[SUCCÈS]\e[0m Tailscale a été installé et configuré sur le LXC $CTID."
echo -e "\e[33m====================================================\e[0m"
echo -e "\e[33m 1. Redémarrez le LXC pour appliquer le périphérique TUN :\e[0m"
echo -e "\e[32m    pct reboot $CTID\e[0m"
echo -e "\e[33m 2. Entrez dans le LXC :\e[0m"
echo -e "\e[32m    pct enter $CTID\e[0m"
echo -e "\e[33m 3. Connectez-vous à votre réseau Tailscale :\e[0m"
echo -e "\e[32m    tailscale up\e[0m"
echo -e "\e[33m====================================================\e[0m"
