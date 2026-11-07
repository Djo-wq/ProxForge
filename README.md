🛠️ ProxForge
Déployez des machines virtuelles et des conteneurs sur Proxmox VE en une seule ligne de commande, sans aucune dépendance externe.

📌 Présentation
ProxForge est une collection de scripts Bash autonomes (standalone) conçus pour automatiser la création et la configuration de VMs et de LXCs sur Proxmox VE (7.x / 8.x).

Chaque script prend en charge l'intégralité du cycle de déploiement :

Téléchargement intelligent : Récupération et mise en cache locale des images officielles (Linux Cloud-Init, FreeBSD/OPNsense, ISOs Windows ou templates LXC).

Configuration matérielle avancée : Paramétrage automatique de l'UEFI/OVMF, du TPM 2.0, des contrôleurs VirtIO et des optimisations de cache (writeback).

Automatisation totale (Unattended) : Injection des fichiers de réponse (comme autounattend.xml) pour s'affranchir des assistants d'installation manuels.

Démarrage instantané : La VM ou le conteneur est prêt et opérationnel en quelques secondes.

📂 Structure du Dépôt
Plaintext
.
├── 📁 linux/
│   ├── create-ubuntu-vm.sh
│   ├── create-debian-vm.sh
│   └── create-fedora-vm.sh
├── 📁 windows/
│   ├── create-windows-vm.sh    (Windows Server)
│   └── create-windows11-vm.sh  (Windows 11 Client)
├── 📁 network/
│   └── create-opnsense-vm.sh
├── 📁 lxc/
│   └── create-docker-lxc.sh
├── 📄 LICENSE
└── 📄 README.md
⚡ Démarrage Rapide
[!IMPORTANT]
Ces scripts modifient les ressources de l'hyperviseur via l'API CLI de Proxmox (qm, pct, pvesm, pvesh) et doivent impérativement être exécutés en tant que root dans le Shell de votre nœud Proxmox.

🐧 Systèmes Linux (Cloud-Init)
Bash
# Ubuntu Server
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/linux/create-ubuntu-vm.sh)"

# Debian Generic Cloud
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/linux/create-debian-vm.sh)"

# Fedora Cloud Base
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/linux/create-fedora-vm.sh)"
🪟 Environnements Windows
(Nécessite d'avoir préalablement placé votre fichier .iso dans le stockage local > ISO Images de Proxmox)

Bash
# Windows Server (avec autounattend.xml & pilotes VirtIO automatiques)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/windows/create-windows-vm.sh)"

# Windows 11 (avec bypass TPM/CPU/SecureBoot et compte local forcé)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/windows/create-windows11-vm.sh)"
🛡️ Réseau & Conteneurisation
Bash
# OPNsense Router/Firewall (via FreeBSD)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/network/create-opnsense-vm.sh)"

# Docker LXC Container (Debian 12 + Docker Compose)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/lxc/create-docker-lxc.sh)"
🛠️ Options & Personnalisation
Il n'est pas nécessaire de modifier le code des scripts pour ajuster vos ressources. Vous pouvez surcharger les variables d'environnement directement à la volée :

Bash
CPU_CORES=4 RAM_SIZE=8192 DISK_SIZE=50G STORAGE=local-zfs \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/<VOTRE-PSEUDO>/ProxForge/main/linux/create-ubuntu-vm.sh)"
⚠️ Remarques de Sécurité & Fonctionnement
[!WARNING]
Comptes Windows Automatisés : Les scripts de création Windows déploient un compte administrateur par défaut avec le mot de passe temporaire : Proxmox2026!. Veillez à le modifier immédiatement après votre première connexion au bureau.

Cache Local intelligent : Les images distantes sont téléchargées une seule fois dans /var/lib/vz/template/iso/. Les déploiements ultérieurs s'exécutent quasi instantanément.

Téléchargement Atomique : Protection intégrée contre les coupures réseau (fichiers .tmp validés uniquement à 100 %).

📜 Licence
Ce projet est distribué sous licence MIT. Vous êtes libre de l'utiliser, de le modifier et de le redistribuer selon vos besoins. (Voir le fichier LICENSE pour plus de détails).
