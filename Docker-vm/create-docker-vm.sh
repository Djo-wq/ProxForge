#!/usr/bin/env bash
# Script de création automatisée d'une VM Docker (Cloud-Init) pour Proxmox VE
set -euo pipefail

# --- 1. CONFIGURATION PAR DÉFAUT ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-docker-vm}"
CPU_CORES="${CPU_CORES:-2}"
RAM_SIZE="${RAM_SIZE:-4096}"
DISK_SIZE="${DISK_SIZE:-20G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# --- 2. GESTION DU TEMPLATE DEBIAN CLOUD VIA PVEAM ---
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Docker (ID: $VMID)..."

# Recherche de la dernière image Debian 12 (Bookworm) Cloud-Init
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
CACHE_FILE="${LOCAL_CACHE_DIR}/debian-12-generic-amd64.qcow2"

if [ ! -f "$CACHE_FILE" ]; then
    echo -e "\e[34m[INFO]\e[0m Téléchargement de l'image Debian 12 Cloud-Init..."
    curl -fL --progress-bar -o "${CACHE_FILE}.tmp" "$DEBIAN_URL"
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
else
    echo -e "\e[32m[OK]\e[0m Image Debian 12 Cloud-Init déjà présente localement : $CACHE_FILE"
fi

# --- 3. PRÉPARATION DE L'IMAGE AVEC VIRT-CUSTOMIZE ---
echo -e "\e[34m[INFO]\e[0m Installation de Docker directement dans l'image (cela peut prendre quelques minutes)..."

# On travaille sur une copie pour ne pas altérer le cache
WORK_FILE="${LOCAL_CACHE_DIR}/docker-vm-${VMID}.qcow2"
cp "$CACHE_FILE" "$WORK_FILE"
trap 'rm -f "$WORK_FILE" "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

# Utilisation de virt-customize pour injecter Docker avant même de créer la VM
virt-customize -a "$WORK_FILE" --install qemu-guest-agent,curl,ca-certificates >/dev/null 2>&1
virt-customize -q -a "$WORK_FILE" --run-command "curl -fsSL https://get.docker.com | sh" >/dev/null 2>&1
virt-customize -q -a "$WORK_FILE" --run-command "systemctl enable docker" >/dev/null 2>&1

# Optimisation du démon Docker (Overlay2 et rotation des logs)
virt-customize -q -a "$WORK_FILE" --run-command "mkdir -p /etc/docker" >/dev/null 2>&1
virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/docker/daemon.json << EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF' >/dev/null 2>&1

# Redimensionnement de l'image préparée
echo -e "\e[34m[INFO]\e[0m Redimensionnement du disque à $DISK_SIZE..."
qemu-img resize "$WORK_FILE" "$DISK_SIZE" >/dev/null 2>&1

# --- 4. CRÉATION DE LA VM ---
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

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

echo -e "\e[34m[INFO]\e[0m Importation du disque virtuel préparé..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2)
DISK_VOL=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as '\K[^']+")

# Ajout du disque avec cache=writeback et du lecteur Cloud-Init
qm set "$VMID" \
    --scsi0 "${DISK_VOL},discard=on,ssd=1,cache=writeback" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket

# --- 5. CONFIGURATION CLOUD-INIT DE BASE ---
# Configuration d'un utilisateur par défaut (docker) et d'un mot de passe (Proxmox2026!)
qm set "$VMID" \
    --ciuser "docker" \
    --cipassword "Proxmox2026!" \
    --ipconfig0 ip=dhcp

echo -e "\n\e[33m[IMPORTANT]\e[0m Utilisateur configuré via Cloud-Init: 'docker' / 'Proxmox2026!'"

# Nettoyage de l'image de travail (on la supprime car elle est maintenant importée dans la VM)
rm -f "$WORK_FILE"
trap 'rm -f "${LOCAL_CACHE_DIR}/"*.tmp 2>/dev/null' EXIT ERR

# --- 6. DÉMARRAGE ---
if [ "$START_VM" == "yes" ]; then
    echo -e "\e[34m[INFO]\e[0m Démarrage de la VM Docker..."
    qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Docker créée avec succès (ID: $VMID) !"
