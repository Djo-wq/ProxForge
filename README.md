⚡ ProxForgeDéployez des machines virtuelles Linux, Windows, des pare-feux OPNsense et des conteneurs Docker sur Proxmox VE — entièrement automatisé, optimisé et sans dépendance externe.📌 Qu'est-ce que ProxForge ?ProxForge est une collection de scripts Bash autonomes (standalone) conçus spécifiquement pour Proxmox VE (7.x / 8.x).Contrairement aux solutions dépendant de frameworks externes, ProxForge automatise l'intégralité du cycle de déploiement directement depuis le shell de votre nœud Proxmox :100% Indépendant : Pas de dépendance envers des bibliothèques distantes complexes.Cache Local Intelligent : Télécharge et met en cache les images Cloud (.qcow2, .img) dans /var/lib/vz/template/iso/ pour accélérer les déploiements futurs.Installations Windows Automatisées : Génère une disquette/USB virtuelle avec autounattend.xml pour contourner les restrictions matérielles (TPM, Secure Boot, RAM) et injecter les pilotes VirtIO en silence.Optimisations de Performance : Prépare des configurations de stockage robustes avec l'option de cache writeback et les sécurités UEFI/OVMF.📂 Structure du DépôtPlaintext.
├── 📁 linux/
│   ├── create-ubuntu-vm.sh     # Ubuntu Cloud-Init (22.04 / 24.04 / 26.04)
│   ├── create-debian-vm.sh     # Debian Generic Cloud (Bookworm / Trixie)
│   └── create-fedora-vm.sh     # Fedora Cloud Base
├── 📁 windows/
│   ├── create-windows-vm.sh    # Windows Server (2019 / 2022 / 2025)
│   └── create-windows11-vm.sh  # Windows 11 Client (Bypass MSA / TPM)
├── 📁 network/
│   └── create-opnsense-vm.sh   # OPNsense Firewall / Routeur (Dual/Single NIC)
├── 📁 lxc/
│   └── create-docker-lxc.sh    # Debian 12 Unprivileged LXC avec Docker Compose
├── 📄 LICENSE
└── 📄 README.md
🚀 Commandes de Déploiement[!IMPORTANT]Ces scripts interagissent directement avec l'API CLI de Proxmox (qm, pct, pvesm, pvesh). Vous devez impérativement les exécuter en tant que root dans le Shell de votre nœud Proxmox.🐧 Distributions Linux (Cloud-Init)Bash# Ubuntu Server
bash linux/create-ubuntu-vm.sh

# Debian Generic Cloud
bash linux/create-debian-vm.sh

# Fedora Cloud Base
bash linux/create-fedora-vm.sh
🪟 Environnements Windows[!NOTE]Pour les scripts Windows, assurez-vous d'avoir préalablement placé votre fichier .iso dans le stockage local > ISO Images de Proxmox.Bash# Windows Server (avec injection des pilotes VirtIO)
bash windows/create-windows-vm.sh

# Windows 11 Client (Bypass vérification matérielle + Compte local forcé)
bash windows/create-windows11-vm.sh
🛡️ Réseau & ConteneurisationBash# OPNsense Routeur & Pare-feu
bash network/create-opnsense-vm.sh

# Docker Engine LXC (Debian 12 + Plugin Compose)
bash lxc/create-docker-lxc.sh
🛠️ Personnalisation AvancéeVous pouvez surcharger les variables d'environnement directement à la volée avant d'exécuter un script pour adapter les ressources à vos besoins :BashCPU_CORES=8 RAM_SIZE=16384 DISK_SIZE=100G STORAGE=local-zfs bash linux/create-ubuntu-vm.sh
VariableDescriptionValeur par défautVMID / CTIDIdentifiant unique de la machineIncrémentation automatique (nextid)CPU_CORESNombre de vCPUs alloués2 (Linux) / 4 (Windows/OPNsense)RAM_SIZEMémoire vive en Mégaoctets2048 (2Go)DISK_SIZETaille du disque virtuel20G – 64GSTORAGEStockage Proxmox ciblelocal-lvmBRIDGEPont réseau virtuelvmbr0🔒 Remarques de Sécurité[!WARNING]Comptes Windows Automatisés : Les scripts de déploiement Windows créent par défaut un compte administrateur local sécurisé avec le mot de passe temporaire :PlaintextProxmox2026!
Veillez à modifier ce mot de passe immédiatement après votre première connexion au bureau.📜 LicenceCe projet est distribué sous licence MIT. Vous êtes libre de l'utiliser, de le modifier et de le redistribuer à des fins personnelles et commerciales.
