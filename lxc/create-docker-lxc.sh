#!/usr/bin/env bash
# ProxForge — Création automatisée d'un LXC Docker (Debian 13) pour Proxmox VE 9.2
set -euo pipefail

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

echo -e "\e[34m[INFO]\e[0m Mise à jour des templates..."
pveam update >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Échec pveam update" >&2; exit 1; }

echo -e "\e[34m[INFO]\e[0m Recherche template Debian 13..."
TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-13-standard" | sort -V | tail -n 1 | awk '{print $2}')
[[ -z "$TEMPLATE_NAME" ]] && { echo -e "\e[31m[ERREUR]\e[0m Template introuvable" >&2; exit 1; }

TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
[[ -f "/var/lib/vz/template/cache/${TEMPLATE_FILE}" ]] || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Téléchargement échoué" >&2; exit 1; }

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" --hostname "$HN" --arch amd64 --ostype debian --cores "$CPU_CORES" --memory "$RAM_SIZE" --swap 0 --net0 name=eth0,bridge="$BRIDGE",ip=dhcp --rootfs "${STORAGE}:${DISK_SIZE}" --unprivileged 1 --features nesting=1,keyctl=1 --description "Docker LXC - ProxForge" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Création échouée" >&2; exit 1; }
CT_CREATED=1

if [[ "$START_LXC" == "yes" ]]; then
  pct start "$CTID" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Démarrage échoué" >&2; exit 1; }
  TIMEOUT=60; COUNT=0
  while ! pct exec "$CTID" -- ping -c1 1.1.1.1 >/dev/null 2>&1; do
    (( COUNT >= TIMEOUT )) && { echo -e "\e[31m[ERREUR]\e[0m Timeout DHCP" >&2; exit 1; }
    sleep 1; (( COUNT++ ))
  done
  pct exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get upgrade -y; apt-get install -y curl ca-certificates gnupg; curl -fsSL https://get.docker.com -o get-docker.sh; sh get-docker.sh; apt-get install -y docker-compose-plugin; mkdir -p /etc/docker; echo "{\"storage-driver\":\"overlay2\",\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}" > /etc/docker/daemon.json; systemctl enable --now docker' >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Installation Docker échouée" >&2; exit 1; }
fi

LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' || echo "")
echo -e "\n\e[32m[SUCCÈS]\e[0m LXC Docker déployé (ID: $CTID) !"
[[ -n "$LXC_IP" ]] && echo -e "\e[36m[INFO]\e[0m Connexion : pct enter $CTID ou ssh root@${LXC_IP}" || echo -e "\e[33m[AVERTISSEMENT]\e[0m IP : pct exec $CTID -- ip a"
