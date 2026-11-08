#!/usr/bin/env bash
# ProxForge — Création automatisée d'un LXC Docker (Debian 13) pour Proxmox VE 9.2
# Compatible: Proxmox VE 7.x | 8.x | 9.x (Debian 13 Trixie)
#
# Usage :
#   bash lxc/create-docker-lxc.sh
#   CPU_CORES=4 RAM_SIZE=4096 DISK_SIZE=16G bash lxc/create-docker-lxc.sh
#
# Variables personnalisables :
#   CTID, HN, CPU_CORES, RAM_SIZE, DISK_SIZE, STORAGE, BRIDGE, START_LXC, TEMPLATE_STORAGE

set -euo pipefail

# ============================================================================
# 1. VALIDATIONS PRÉCOCES
# ============================================================================

if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Ce script doit être exécuté en tant que root." >&2
  exit 1
fi

for cmd in pct pveam pvesh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "\e[31m[ERREUR]\e[0m La commande '$cmd' est requise mais introuvable." >&2
    exit 1
  fi
done

# ============================================================================
# 2. CONFIGURATION
# ============================================================================

CTID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-docker-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-2048}"
DISK_SIZE="${DISK_SIZE:-8G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

if [[ ! "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]]; then
  echo -e "\e[31m[ERREUR]\e[0m DISK_SIZE doit être au format '8G' (en Go uniquement)." >&2
  exit 1
fi

# ============================================================================
# 3. CLEANUP
# ============================================================================

CT_CREATED=0

cleanup() {
  local exit_code=$?
  if (( exit_code != 0 )) && (( CT_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression du conteneur $CTID..." >&2
    pct stop "$CTID" >/dev/null 2>&1 || true
    pct destroy "$CTID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT ERR

# ============================================================================
# 4. TEMPLATE DEBIAN 13
# ============================================================================

echo -e "\e[34m[INFO]\e[0m Mise à jour de la liste des templates..."
if ! pveam update >/dev/null 2>&1; then
  echo -e "\e[31m[ERREUR]\e[0m Échec de la mise à jour des templates." >&2
  exit 1
fi

echo -e "\e[34m[INFO]\e[0m Recherche du template Debian 13 (Trixie)..."
TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-13-standard" | sort -V | tail -n 1 | awk '{print $2}')

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de trouver le template Debian 13." >&2
  echo -e "\e[33m[INFO]\e[0m Essayez : pveam available -section system | grep debian" >&2
  exit 1
fi

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
CACHE_PATH="/var/lib/vz/template/cache/${TEMPLATE_FILE}"

if [[ -f "$CACHE_PATH" ]]; then
  echo -e "\e[32m[OK]\e[0m Template déjà présent : $TEMPLATE_FILE"
else
  echo -e "\e[34m[INFO]\e[0m Téléchargement du template ${TEMPLATE_FILE}..."
  if ! pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null 2>&1; then
    echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement." >&2
    exit 1
  fi
  echo -e "\e[32m[OK]\e[0m Template téléchargé."
fi

# ============================================================================
# 5. CRÉATION CONTENEUR
# ============================================================================

echo -e "\e[34m[INFO]\e[0m Création du conteneur LXC (Unprivileged + Nesting)..."

if ! pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "$HN" \
  --arch amd64 \
  --ostype debian \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --description "Docker LXC - ProxForge" >/dev/null 2>&1; then
  echo -e "\e[31m[ERREUR]\e[0m Échec de la création du conteneur." >&2
  exit 1
fi

CT_CREATED=1
echo -e "\e[32m[OK]\e[0m Conteneur créé."

# ============================================================================
# 6. INSTALLATION DOCKER
# ============================================================================

if [[ "$START_LXC" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage du conteneur..."
  if ! pct start "$CTID" >/dev/null 2>&1; then
    echo -e "\e[31m[ERREUR]\e[0m Échec du démarrage." >&2
    exit 1
  fi

  echo -e "\e[34m[INFO]\e[0m Attente IP DHCP..."
  TIMEOUT=60
  COUNT=0
  while ! pct exec "$CTID" -- ping -c1 1.1.1.1 >/dev/null 2>&1; do
    if (( COUNT >= TIMEOUT )); then
      echo -e "\e[31m[ERREUR]\e[0m Timeout DHCP." >&2
      exit 1
    fi
    sleep 1
    (( COUNT++ ))
  done

  echo -e "\e[34m[INFO]\e[0m Installation de Docker..."
  if ! pct exec "$CTID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl ca-certificates gnupg
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    apt-get install -y docker-compose-plugin
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
    systemctl enable --now docker
  ' >/dev/null 2>&1; then
    echo -e "\e[31m[ERREUR]\e[0m Échec installation Docker." >&2
    exit 1
  fi
fi

# ============================================================================
# 7. RÉSULTAT
# ============================================================================

LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' || echo "IP non trouvée")

echo -e ""
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[32m[SUCCÈS]\e[0m  LXC Docker déployé (ID: $CTID) !"
echo -e "\e[32m[SUCCÈS]\e[0m ============================================"
echo -e "\e[36m[INFO]\e[0m Pour vous connecter depuis Proxmox :"
echo -e "\e[36m[INFO]\e[0m   pct enter $CTID"
if [[ -n "$LXC_IP" && "$LXC_IP" != "IP non trouvée" ]]; then
  echo -e "\e[36m[INFO]\e[0m Depuis votre machine :"
  echo -e "\e[36m[INFO]\e[0m   ssh root@${LXC_IP}"
else
  echo -e "\e[33m[AVERTISSEMENT]\e[0m Trouver l'IP : pct exec $CTID -- ip a"
fi
echo -e ""
