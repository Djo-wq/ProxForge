#!/usr/bin/env bash
# Script de création automatisée VM Windows Server avec Injection VirtIO (Optimisé)
set -euo pipefail

# --- 1. CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-windows-server}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-4096}"
DISK_SIZE="${DISK_SIZE:-60}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# À MODIFIER : Nom exact de votre fichier ISO Windows présent sur Proxmox
WINDOWS_ISO="${WINDOWS_ISO:-windows-server-2025.iso}" 
ISO_STORAGE="local"
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Windows (ID: $VMID)..."

# --- 2. VÉRIFICATIONS ISO ---
if [ ! -f "${LOCAL_CACHE_DIR}/${WINDOWS_ISO}" ]; then
  echo -e "\e[31m[ERREUR]\e[0m L'ISO Windows '${WINDOWS_ISO}' est introuvable dans ${LOCAL_CACHE_DIR}."
  exit 1
fi

VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_FILE="virtio-win-stable.iso"

if [ ! -f "${LOCAL_CACHE_DIR}/${VIRTIO_FILE}" ]; then
  echo -e "\e[34m[INFO]\e[0m Téléchargement du CD des pilotes VirtIO..."
  curl -L --progress-bar -o "${LOCAL_CACHE_DIR}/${VIRTIO_FILE}" "$VIRTIO_URL"
fi

# --- 3. GÉNÉRATION DE LA CLÉ USB VIRTUELLE (autounattend.xml) ---
echo -e "\e[34m[INFO]\e[0m Génération du fichier de réponse automatisé..."
TEMP_DIR=$(mktemp -d)
IMG_FILE="${TEMP_DIR}/unattend.img"

# Création d'une image FAT de 2.8Mo (évite les erreurs d'espace insuffisant)
dd if=/dev/zero of="$IMG_FILE" bs=1k count=2880 2>/dev/null
mkfs.fat -F 12 "$IMG_FILE" >/dev/null

cat << 'EOF' > "${TEMP_DIR}/autounattend.xml"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\vioscsi\2k22\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\vioscsi\2k22\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\vioscsi\2k22\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>D:\vioscsi\2k19\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\vioscsi\2k19\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>F:\vioscsi\2k19\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>D:\NetKVM\2k22\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>E:\NetKVM\2k22\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9"><Path>F:\NetKVM\2k22\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="10"><Path>D:\NetKVM\2k19\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="11"><Path>E:\NetKVM\2k19\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="12"><Path>F:\NetKVM\2k19\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Proxmox2026!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>Proxmox2026!</Value>
          <PlainText>true</PlainText>
        </Password>
        <Username>Administrator</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd.exe /c "for %d in (D E F G) do if exist %d:\virtio-win-guest-tools.exe %d:\virtio-win-guest-tools.exe /quiet /norestart"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF

# FIX : Conversion CRLF pour que Windows lise le fichier XML sans erreur de parsing
sed -i 's/$/\r/' "${TEMP_DIR}/autounattend.xml"

mkdir -p "${TEMP_DIR}/mnt"

# FIX : Démontage propre et forcé via fonction
cleanup() {
  if mountpoint -q "${TEMP_DIR}/mnt"; then
    sync
    sleep 1
    umount -l "${TEMP_DIR}/mnt" || true
  fi
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT ERR

mount -o loop "$IMG_FILE" "${TEMP_DIR}/mnt"
cp "${TEMP_DIR}/autounattend.xml" "${TEMP_DIR}/mnt/"
sync
sleep 1
umount "${TEMP_DIR}/mnt"
trap - EXIT ERR # Annulation du trap une fois démonté proprement

UNATTEND_FINAL="${LOCAL_CACHE_DIR}/unattend-${VMID}.img"
mv "$IMG_FILE" "$UNATTEND_FINAL"
chmod 644 "$UNATTEND_FINAL" # FIX : Droits pour l'accès QEMU KVM
rm -rf "${TEMP_DIR}"

# --- 4. CRÉATION DE LA VM (QM) ---
echo -e "\e[34m[INFO]\e[0m Création de la VM Windows..."

qm create "$VMID" \
  --name "$HN" \
  --agent 1 \
  --bios ovmf \
  --machine q35 \
  --cpu host \
  --cores "$CPU_CORES" \
  --memory "$RAM_SIZE" \
  --net0 virtio,bridge="$BRIDGE" \
  --ostype win11 \
  --scsihw virtio-scsi-pci

qm set "$VMID" --tpmstate0 "${STORAGE}:0,version=v2.0"
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

# FIX : Optimisation Writeback pour Windows
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1,cache=writeback"

# Attachement des ISOs
qm set "$VMID" --ide0 "${ISO_STORAGE}:iso/${WINDOWS_ISO},media=cdrom"
qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${VIRTIO_FILE},media=cdrom"

# Injection de la fausse clé USB
qm set "$VMID" --args "-drive file=${UNATTEND_FINAL},format=raw,if=none,id=drive-usb-unattend,readonly=on -device usb-storage,drive=drive-usb-unattend"

# Boot order
qm set "$VMID" --boot "order=ide0;scsi0"

# --- 5. DÉMARRAGE ---
if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM..."
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Windows (ID: $VMID) prête pour l'installation automatisée !"
