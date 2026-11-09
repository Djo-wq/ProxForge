<div align="center">

```text
██████╗ ██████╗  ██████╗ ██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
███████║██████╔╝██║   ██║ ╚███╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗  
██║     ██╔══██║██║   ██║ ██╔██╗ ██╔══╝  ██║   ██║██╔══██║██║   ██║██╔══╝  
██║     ██║  ██║╚██████╔╝██╔╝ ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
```

**⚡ Déployez des machines virtuelles Linux et Windows, des pare-feux OPNsense, des LXC applicatifs et des conteneurs Docker sur Proxmox VE 9.2 : entièrement automatisé, robuste et sans dépendance externe.**

```bash
$ ssh root@proxmox
$ ./proxforge --deploy <linux|windows|opnsense|docker>
```

![Bash](https://img.shields.io/badge/langage-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Proxmox VE](https://img.shields.io/badge/Proxmox_VE-9.2%20%7C%20Debian%2013-E57000?style=for-the-badge&logo=proxmox&logoColor=white)
![Zéro dépendance](https://img.shields.io/badge/z%C3%A9ro_d%C3%A9pendance-00C853?style=for-the-badge)
![Licence](https://img.shields.io/badge/licence-MIT-212121?style=for-the-badge)

</div>

---

## 📚 Sommaire

- [📌 À propos](#à-propos)
- [✨ Fonctionnalités](#fonctionnalités)
- [📋 Prérequis](#prérequis)
- [🗂️ Structure du projet](#structure-du-projet)
- [🚀 Déploiement](#déploiement)
- [🔧 Personnalisation](#personnalisation)
- [🔒 Sécurité](#sécurité)
- [📜 Licence](#licence)

---

## À propos

ProxForge est une collection de **scripts Bash autonomes (standalone)** conçus spécifiquement pour **Proxmox VE 9.2** (Debian 13 « Trixie »).

Contrairement aux solutions qui reposent sur des frameworks externes, ProxForge automatise l'intégralité du cycle de déploiement **directement depuis le shell de votre nœud Proxmox** : aucune infrastructure supplémentaire, aucun agent, aucune configuration complexe.

> [!IMPORTANT]
> Les scripts interagissent directement avec l'API CLI de Proxmox (`qm`, `pct`, `pveam`, `pvesh`). Vous devez impérativement les exécuter en tant que **`root`** dans le shell de votre nœud Proxmox.

---

## Fonctionnalités

| | Fonctionnalité | Description |
| :---: | --- | --- |
| 🧩 | **100 % autonome** | Aucune dépendance envers des bibliothèques ou des frameworks distants. |
| 💾 | **Cache local intelligent** | Les images Cloud (`.qcow2`, `.img`) sont téléchargées puis mises en cache dans `/var/lib/vz/template/iso/` pour accélérer les déploiements futurs. |
| 🪟 | **Windows automatisé** | Génère une disquette/USB virtuelle avec `autounattend.xml` pour contourner les restrictions matérielles (TPM, Secure Boot, RAM) et injecter les pilotes VirtIO en silence. |
| ⚡ | **Performances optimisées** | Configurations de stockage robustes avec l'option de cache `writeback` et sécurités UEFI/OVMF préconfigurées. |
| ✅ | **Validations précoces** | Contrôle des privilèges `root` et des commandes requises avant toute action, avec `set -euo pipefail` en tête de chaque script. |
| 🧯 | **Auto-nettoyage** | En cas d'échec en cours de déploiement, la VM ou le conteneur partiellement créé est automatiquement supprimé : aucun déploiement fantôme. |
| 🌐 | **LXC prêts à l'emploi** | Attente de l'IP DHCP, installation silencieuse de l'application et affichage de l'URL d'accès à la fin du script. |

---

## Prérequis

- Un nœud **Proxmox VE 9.2** (Debian 13 « Trixie ») opérationnel.
- Un accès **root** au shell du nœud.
- *(VM Windows uniquement)* votre fichier `.iso` placé dans le stockage Proxmox (voir la note Windows dans la section [Déploiement](#déploiement)).

---

## Structure du projet

Tous les scripts suivent la même structure standardisée : validations en amont, variables surchargeables, nettoyage automatique en cas d'échec et messages colorés.

```text
ProxForge/
├── linux/                          # VM Cloud-Init
│   ├── create-ubuntu-vm.sh
│   ├── create-debian-vm.sh
│   ├── create-kali-vm.sh
│   ├── create-arch-linux-vm.sh
│   └── create-fedora-vm.sh
├── lxc/                            # Conteneurs applicatifs
│   ├── Adblock & DNS/
│   │   ├── create-adguard-lxc.sh
│   │   ├── create-pihole-lxc.sh
│   │   ├── create-powerdns-lxc.sh
│   │   └── create-technitium-lxc.sh
│   ├── Databases/
│   │   ├── create-mariadb-lxc.sh
│   │   ├── create-mongodb-lxc.sh
│   │   └── create-postgresql-lxc.sh
│   ├── Media & Streaming/
│   │   ├── create-immich-lxc.sh
│   │   └── create-jellyfin-lxc.sh
│   └── Remote Access & VPN/
│       ├── create-Cloudflared-lxc.sh
│       ├── create-netbird-lxc.sh
│       ├── create-Tailscale-lxc.sh
│       └── create-wireguard-lxc.sh
├── windows/                        # VM Windows
│   ├── create-windows11-vm.sh
│   ├── create-win10-vm.sh
│   └── create-winserver2025-vm.sh
├── opnsense/
│   └── create-opnsense-vm.sh
└── docker/
    └── create-docker-lxc.sh
```

---

## Déploiement

Commencez par cloner le dépôt sur votre nœud Proxmox :

```bash
git clone https://github.com/<votre-utilisateur>/ProxForge.git
cd ProxForge
```

### 🐧 Machines virtuelles Linux

```bash
bash linux/create-ubuntu-vm.sh
```

### 🪟 Machines virtuelles Windows

> [!NOTE]
> Pour les scripts Windows, assurez-vous d'avoir préalablement placé votre fichier `.iso` dans le stockage **local → ISO Images** de Proxmox.

```bash
bash windows/create-windows11-vm.sh
```

### 🛡️ Pare-feux OPNsense

```bash
bash opnsense/create-opnsense-vm.sh
```

### 📦 Conteneurs LXC applicatifs

```bash
bash "lxc/Adblock & DNS/create-pihole-lxc.sh"
bash "lxc/Databases/create-postgresql-lxc.sh"
bash "lxc/Remote Access & VPN/create-wireguard-lxc.sh"
```

### 🐳 Conteneurs Docker

```bash
bash docker/create-docker-lxc.sh
```

---

## Personnalisation

Surchargez les variables d'environnement à la volée, directement avant d'exécuter un script, pour adapter les ressources à vos besoins :

```bash
CPU_CORES=8 RAM_SIZE=16384 DISK_SIZE=100G STORAGE=local-zfs bash linux/create-ubuntu-vm.sh
```

| Variable | Description | Valeur par défaut |
| --- | --- | --- |
| `VMID` / `CTID` | Identifiant unique de la machine | Incrément automatique (`nextid`) |
| `CPU_CORES` | Nombre de vCPUs alloués | `2` (Linux) / `4` (Windows, OPNsense) |
| `RAM_SIZE` | Mémoire vive (Mo) | `2048` (2 Go) |
| `DISK_SIZE` | Taille du disque virtuel | `20G` – `64G` |
| `STORAGE` | Stockage Proxmox cible | `local-lvm` |
| `BRIDGE` | Pont réseau virtuel | `vmbr0` |
| `CIUSER` | Utilisateur Cloud-Init créé dans la VM | `admin` |
| `SSH_PUBKEY_FILE` | Clé publique SSH à injecter (ex. `/root/.ssh/id_ed25519.pub`) | *(vide)* |
| `CIPASSWORD` | Mot de passe initial Cloud-Init | *(vide)* |
| `IPCONFIG0` | Configuration réseau Cloud-Init | `ip=dhcp` |
| `TEMPLATE_STORAGE` | Stockage des templates LXC (`pveam`) | `local` |
| `START_VM` / `START_LXC` | Démarrage automatique après création | `yes` |

> [!TIP]
> Pour les VM Cloud-Init, privilégiez `SSH_PUBKEY_FILE` plutôt que `CIPASSWORD` : un mot de passe passé en variable d'environnement transite brièvement en clair dans la liste des processus.

---

## Sécurité

> [!WARNING]
> **Comptes automatisés** : les scripts de déploiement Windows, ainsi que les applications installées automatiquement dans les LXC (ex. Pi-hole), créent par défaut un compte administrateur avec le mot de passe temporaire :
>
> ```
> Proxmox2026!
> ```
>
> Veillez à **modifier ce mot de passe immédiatement** après votre première connexion (session Windows ou interface web de l'application).

---

## Licence

Ce projet est distribué sous licence **MIT**. Vous êtes libre de l'utiliser, de le modifier et de le redistribuer, à des fins personnelles comme commerciales.

## ProxForge CLI (phases 1–11)

The current modular ProxForge engine is operated through `proxforge.sh`:

```bash
./proxforge.sh --help
./proxforge.sh doctor
./proxforge.sh module list
./proxforge.sh module validate fedora
./proxforge.sh module image debian latest
./proxforge.sh profile list
./proxforge.sh pve doctor
./proxforge.sh deploy fedora stable standard local-lvm vmbr0 --name fedora-lab --vmid auto
./proxforge.sh operation list
```

Use `--config FILE` before the command to select an explicit JSON configuration override. The CLI includes read-only module, profile, Proxmox and image-cache inspection; VM creation remains explicit through `deploy`. Debian's official-TLS checksum trust mode stays disabled by default.

See [Phase 9 CLI documentation](docs/phase-9-complete-cli.md) for the command reference and [Phase 8 Debian module notes](docs/phase-8-debian-module.md) for Debian's image trust policy.


### System installation (Phase 10)

On a Proxmox VE 9.x node running Debian 13, install the modular CLI as root:

```bash
sudo bash scripts/install.sh
```

Optional flags:

```bash
sudo bash scripts/install.sh --install-dependencies
sudo bash scripts/install.sh --provision-fedora-keyring
```

The installer keeps the JSON configuration under `/etc/proxforge`, operation state and image cache under `/var/lib/proxforge`, and logs under `/var/log/proxforge`. Fedora key provisioning is an explicit opt-in; Debian's official-TLS checksum policy remains disabled by default.

The default uninstaller preserves configuration and data:

```bash
sudo bash /usr/local/lib/proxforge/scripts/uninstall.sh
```

Configuration backup/removal and state/cache/log removal require explicit `--remove-config` and `--remove-data` flags. See [Phase 10 installation documentation](docs/phase-10-installation.md) for the full filesystem layout, prerequisites and staging tests.


### Final audit (Phase 11)

The final audit fixes installed CLI entry-point resolution and expands installation regression coverage. See [Phase 11 audit and stabilization report](docs/phase-11-final-audit.md).
