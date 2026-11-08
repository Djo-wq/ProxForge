#!/usr/bin/env bash
# Script de création automatisée d'un LXC Docker (Debian 13) pour Proxmox VE 9.2
set -euo pipefail

# --- CONFIGURATION ---
CTID_DEFAULT=$(pvesh get /cluster/nextid)
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-docker-lxc}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

# Validation DISK_SIZE
if [[ ! "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]]; then
  echo -e "\e[31m[ERREUR]\e[0m DISK_SIZE doit être au format '8G' (en Go uniquement)."
  exit 1
fi

CT_CREATED=0

cleanup() {
  local exit_code=$?
  if (( exit_code != 0 )) && (( CT_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression du conteneur $CTID..."
    pct stop "$CTID" >/dev/null 2>&1 || true
    pct destroy "$CTID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m Début de la création du LXC Docker (ID: $CTID)..."

# --- GESTION DU TEMPLATE DEBIAN 13 ---
echo -e "\e[34m[INFO]\e[0m Mise à jour de la liste des templates Proxmox..."
pveam update >/dev/null

echo -e "\e[34m[INFO]\e[0m Recherche du template Debian 13 (Trixie)..."
TEMPLATE_NAME=$(pveam available -section system | grep "debian-13-standard" | sort -V | tail -n 1 | awk '{print $2}')

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le template Debian 13."
  echo -e "\e[31m[ERREUR]\e[0m Essayez : pveam available -section system | grep debian"
  exit 1
fi

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
CACHE_PATH="/var/lib/vz/template/cache/${TEMPLATE_FILE}"

if [[ -f "$CACHE_PATH" ]]; then
  echo -e "\e[32m[OK]\e[0m Template déjà présent en cache : $TEMPLATE_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement du template ${TEMPLATE_FILE}..."
  if ! pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"; then
    echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement du template."
    exit 1
  fi
fi

# --- CRÉATION DU CONTENEUR LXC ---
echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC (Unprivileged + Nesting)..."

# L'option "nesting=1" et "keyctl=1" sont OBLIGATOIRES pour Docker dans LXC
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
CT_CREATED=1

# --- DÉMARRAGE ET INSTALLATION DE DOCKER ---
if [[ "$START_LXC" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur LXC..."
  pct start "$CTID"

  echo -e "\e[34m[INFO]\e[0m Attente de l'attribution de l'IP (DHCP)..."
  # Timeout de 60 secondes pour obtenir une IP
  TIMEOUT=60
  COUNT=0
  while ! pct exec "$CTID" -- ping -c1 1.1.1.1 >/dev/null 2>&1; do
    if (( COUNT >= TIMEOUT )); then
      echo -e "\e[31m[ERREUR]\e[0m Timeout : le conteneur n'a pas obtenu d'IP DHCP."
      exit 1
    fi
    sleep 1
    (( COUNT++ ))
  done

  echo -e "\e[34m[INFO]\e[0m Installation de Docker et Docker-Compose..."
  pct exec "$CTID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl ca-certificates gnupg

    # Installation officielle de Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh

    # Installation du plugin Compose
    apt-get install -y docker-compose-plugin

    # Configuration Docker
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
    {
      "storage-driver": "overlay2",
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "10m",
        "max-file": "3"
      }
    }
    EOF

    # Activation du service
    systemctl enable --now docker
  '

  if [[ $? -ne 0 ]]; then
    echo -e "\e[31m[ERREUR]\e[0m Échec de l'installation de Docker dans le conteneur."
    exit 1
  fi
fi

# Récupération de l'IP pour l'affichage
LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "IP non trouvée")

echo -e "\n\e[32m[SUCCÈS]\e[0m Le LXC Docker a été déployé avec succès (ID: $CTID) !"
echo -e "\e[33m====================================================\e[0m"
if [[ -n "$LXC_IP" && "$LXC_IP" != "IP non trouvée" ]]; then
  echo -e "\e[33m Pour vous y connecter depuis l'hôte Proxmox :\e[0m"
  echo -e "\e[32m pct enter $CTID\e[0m"
  echo -e "\e[33m Ou depuis votre machine :\e[0m"
  echo -e "\e[32m ssh root@${LXC_IP}\e[0m"
else
  echo -e "\e[33m Pour trouver l'IP du conteneur :\e[0m"
  echo -e "\e[32m pct exec $CTID -- ip a\e[0m"
fi
echo -e "\e[33m====================================================\e[0m"
