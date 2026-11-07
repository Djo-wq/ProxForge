#!/usr/bin/env bash
# Script de création automatisée VM Windows 11 (Bypass total + VirtIO + BypassNRO)
set -euo pipefail

# --- 1. CONFIGURATION ---
VMID_DEFAULT=$(pvesh get /cluster/nextid)
VMID="${VMID:-$VMID_DEFAULT}"
HN="${HN:-win11-vm}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-4096}"
DISK_SIZE="${DISK_SIZE:-64}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_VM="${START_VM:-yes}"

# À MODIFIER : Nom exact de votre ISO Windows 11
WINDOWS_ISO="${WINDOWS_ISO:-windows-11-24h2.iso}" 
ISO_STORAGE="local"
LOCAL_CACHE_DIR="/var/lib/vz/template/iso"

echo -e "\e[34m[INFO]\e[0m Début de la création de la VM Windows 11 (ID: $VMID)..."

# --- 2. VÉRIFICATIONS ISO ---
if [ ! -f "${LOCAL_CACHE_DIR}/${WINDOWS_ISO}" ]; then
  echo -e "\e[31m[ERREUR]\e[0m L'ISO Windows 11 '${WINDOWS_ISO}' est introuvable dans ${LOCAL_CACHE_DIR}."
  exit 1
fi

VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_FILE="virtio-win-stable.iso"

if [ ! -f "${LOCAL_CACHE_DIR}/${VIRTIO_FILE}" ]; then
  echo -e "\e[34m[INFO]\e[0m Téléchargement du CD des pilotes VirtIO..."
  curl -fL --progress-bar -o "${LOCAL_CACHE_DIR}/${VIRTIO_FILE}.tmp" "$VIRTIO_URL"
  mv "${LOCAL_CACHE_DIR}/${VIRTIO_FILE}.tmp" "${LOCAL_CACHE_DIR}/${VIRTIO_FILE}"
fi

# --- 3. GÉNÉRATION DE LA CLÉ USB VIRTUELLE (autounattend.xml) ---
echo -e "\e[34m[INFO]\e[0m Génération du fichier de réponse automatisé (Bypass MSA & TPM)..."
TEMP_DIR=$(mktemp -d)
IMG_FILE="${TEMP_DIR}/unattend.img"

# Création d'une image FAT de 2.8Mo
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
      <RunSynchronous>
        <!-- Bypass strict des vérifications matérielles Win11 (CPU/TPM/RAM/Disque/SecureBoot) -->
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>D:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>F:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <!-- Fallback sur Windows 10 si pilotes w11 absents -->
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>D:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>E:\vioscsi\w10\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>
  
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <!-- CORRECTION CRITIQUE 24H2 : Force Windows à proposer le compte local sans internet -->
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
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
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password><Value>Proxmox2026!</Value><PlainText>true</PlainText></Password>
            <Description>Admin Local</Description>
            <DisplayName>ProxmoxUser</DisplayName>
            <Group>Administrators</Group>
            <Name>ProxmoxUser</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Password><Value>Proxmox2026!</Value><PlainText>true</PlainText></Password>
        <Username>ProxmoxUser</Username>
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

# Conversion des fins de lignes (CRLF obligatoire pour WinPE)
sed -i 's/$/\r/' "${TEMP_DIR}/autounattend.xml"

mkdir -p "${TEMP_DIR}/mnt"

# FIX : Nettoyage 100% sécurisé (Même en cas de crash/Ctrl+C)
cleanup() {
  if mountpoint -q "${TEMP_DIR}/mnt" 2>/dev/null; then
    sync; sleep 1; umount -l "${TEMP_DIR}/mnt" || true
  fi
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT ERR

mount -o loop "$IMG_FILE" "${TEMP_DIR}/mnt"
cp "${TEMP_DIR}/autounattend.xml" "${TEMP_DIR}/mnt/"
sync; sleep 1; umount "${TEMP_DIR}/mnt"

UNATTEND_FINAL="${LOCAL_CACHE_DIR}/unattend-${VMID}.img"
mv "$IMG_FILE" "$UNATTEND_FINAL"
chmod 644 "$UNATTEND_FINAL"

# Le trap "cleanup" supprimera proprement le dossier temporaire qui est désormais vide.

# --- 4. CRÉATION DE LA VM (QM) ---
echo -e "\e[34m[INFO]\e[0m Création de la VM Windows 11..."

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

# FIX : Optimisation "cache=writeback" pour booster l'installation
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1,cache=writeback"

# Attachement des ISOs
qm set "$VMID" --ide0 "${ISO_STORAGE}:iso/${WINDOWS_ISO},media=cdrom"
qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${VIRTIO_FILE},media=cdrom"

# Injection de la clé USB d'automatisation
qm set "$VMID" --args "-drive file=${UNATTEND_FINAL},format=raw,if=none,id=drive-usb-unattend,readonly=on -device usb-storage,drive=drive-usb-unattend"

# Ordre de boot (CD en premier, puis le disque)
qm set "$VMID" --boot "order=ide0;scsi0"

# --- 5. DÉMARRAGE ---
if [ "$START_VM" == "yes" ]; then
  echo -e "\e[34m[INFO]\e[0m Démarrage de la VM dans 3 secondes..."
  sleep 3
  qm start "$VMID"
fi

echo -e "\n\e[32m[SUCCÈS]\e[0m VM Windows 11 préparée avec succès (ID: $VMID) !"
