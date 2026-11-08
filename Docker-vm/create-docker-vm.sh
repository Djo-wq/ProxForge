#!/usr/bin/env bash
# Script de création automatisée d'une VM Docker (Cloud-Init) pour Proxmox VE 9.2
set -euo pipefail

# --- CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-docker-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-4096}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# Validation DISK_SIZE
if [[ ! "$DISK_SIZE" =~ ^[0-9]+[Gg]$ ]]; then
  echo -e "\e[31m[ERREUR]\e[0m DISK_SIZE doit être au format '20G' (en Go uniquement)."
  exit 1
fi

LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
VM_CREATED=0

cleanup() {
  local exit_code=$?
  rm -f "${LOCAL_CACHE_DIR}"/docker-*.tmp 2>/dev/null || true
  if (( exit_code != 0 )) && (( VM_CREATED )); then
    echo -e "\e[33m[NETTOYAGE]\e[0m Suppression de la VM $VMID..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Docker (ID: $VMID)..."

# --- TÉLÉCHARGEMENT DEBIAN 13 (Trixie) pour Proxmox 9.2 ---
# Utilisation de Debian 13 qui est la base de Proxmox VE 9.2
DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
CACHE_FILE="${LOCAL_CACHE_DIR}/debian-13-genericcloud-amd64.qcow2"

if [[ ! -f "$CACHE_FILE" ]]; then
  echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image Debian 13 Cloud-Init..."
  if ! curl -L --progress-bar -o "${CACHE_FILE}.tmp" "$DEBIAN_URL"; then
    rm -f "${CACHE_FILE}.tmp"
    echo -e "\e[31m[ERREUR]\e[0m Échec du téléchargement : $DEBIAN_URL"
    exit 1
  fi
  mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
else
  echo -e "\e[32m[OK]\e[0m Image Debian 13 déjà en cache."
fi

# --- CRÉATION DE LA VM ---
echo -e "\e[34m[INFO]\e[0m Création de la VM..."
qm create "$VMID" \
  --name "$HN" \
  --agent 1 \
  --bios ovmf \
  --machine q35 \
  --cpu host \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 \
  --onboot 1 \
  --scsihw virtio-scsi-pci
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Import du disque..."
qm importdisk "$VMID" "$CACHE_FILE" "$STORAGE" --format qcow2

DISK_VOL=$(qm config "$VMID" | awk -F: '/^unused0:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
if [[ -z "$DISK_VOL" ]]; then
  echo -e "\e[31m[ERREUR]\e[0m Impossible de récupérer le volume disque."
  exit 1
fi

qm set "$VMID" --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket
qm resize "$VMID" scsi0 "$DISK_SIZE"

# --- CONFIGURATION CLOUD-INIT ---
# Utilisateur par défaut
qm set "$VMID" \
  --ciuser "docker" \
  --cipassword "Proxmox2026!" \
  --ipconfig0 "ip=dhcp" \
  --nameserver "8.8.8.8,8.8.4.4"

# Configuration Cloud-Init pour installer Docker au premier démarrage
# Création d'un fichier user-data
USER_DATA_FILE="${LOCAL_CACHE_DIR}/docker-userdata-${VMID}.yml"
cat > "$USER_DATA_FILE" << 'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
  - gnupg

runcmd:
  # Installation de Docker
  - curl -fsSL https://get.docker.com | sh
  # Installation de Docker Compose
  - mkdir -p /usr/local/lib/docker/cli-plugins
  - curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
  - chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  # Configuration Docker
  - mkdir -p /etc/docker
  - |
    cat > /etc/docker/daemon.json << 'DOCKER_EOF'
    {
      "storage-driver": "overlay2",
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "10m",
        "max-file": "3"
      }
    }
    DOCKER_EOF
  # Activation du service Docker
  - systemctl enable --now docker
  # Ajout de l'utilisateur docker au groupe docker
  - usermod -aG docker docker

final_message: "VM Docker prête ! Connectez-vous avec : ssh docker@<IP>"
EOF

# Attacher le user-data via cloud-init
qm cloudinit dump "$VMID" ide2 --user
cat "$USER_DATA_FILE" | qm cloudinit push "$VMID" ide2 --user
rm -f "$USER_DATA_FILE"

# --- DÉMARRAGE ---
if [[ "$START_VM" == "yes" ]]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM Docker..."
  qm start "$VMID"
  echo -e "\e[34m[INFO]\e[0m Docker sera installé automatiquement au premier démarrage."
  echo -e "\e[34m[INFO]\e[0m Cela peut prendre 2-5 minutes selon votre connexion Internet."
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Docker créée (ID: $VMID) !"
echo -e "\e[33m[IMPORTANT]\e[0m Utilisateur : 'docker' / Mot de passe : 'Proxmox2026!'"
echo -e "\e[33m[IMPORTANT]\e[0m Docker sera installé automatiquement au premier démarrage."
