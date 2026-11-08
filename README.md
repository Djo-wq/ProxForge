██████╗ ██████╗  ██████╗ ██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
███████║██████╔╝██║   ██║ ╚███╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗  
██║     ██╔══██║██║   ██║ ██╔██╗ ██╔══╝  ██║   ██║██╔══██║██║   ██║██╔══╝  
██║     ██║  ██║╚██████╔╝██╔╝ ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝

</div>

**⚡ Déployez des machines virtuelles Linux, Windows, des pare-feux OPNsense et des conteneurs LXC/Docker sur Proxmox VE : entièrement automatisé, optimisé et sans dépendance externe.**

```bash
$ ssh root@proxmox
$ ./proxforge --deploy <linux|lxc|windows|opnsense|docker>
```

![Bash](https://img.shields.io/badge/langage-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Proxmox VE](https://img.shields.io/badge/Proxmox_VE-7.x%20%7C%208.x%20%7C%209.2-E57000?style=for-the-badge&logo=proxmox&logoColor=white)
![Zéro dépendance](https://img.shields.io/badge/zéro_dépendance-00C853?style=for-the-badge)
![Licence](https://img.shields.io/badge/licence-MIT-212121?style=for-the-badge)

</div>

---

## 📚 Sommaire

- [📌 À propos](#-à-propos)
- [✨ Fonctionnalités](#-fonctionnalités)
- [📋 Prérequis](#-prérequis)
- [🚀 Déploiement](#-déploiement)
- [🔧 Personnalisation](#-personnalisation)
- [🔒 Sécurité](#-sécurité)
- [📝 Changelog](#-changelog)
- [📜 Licence](#-licence)

---

## 📌 À propos

**ProxForge** est une collection de **scripts Bash autonomes (standalone)** conçus spécifiquement pour **Proxmox VE 7.x / 8.x / 9.2** (basé sur Debian 13 "Trixie").

Contrairement aux solutions qui reposent sur des frameworks externes, ProxForge automatise l'intégralité du cycle de déploiement **directement depuis le shell de votre nœud Proxmox** : aucune infrastructure supplémentaire, aucun agent, aucune configuration complexe.

> [!IMPORTANT]
> Les scripts interagissent directement avec l'API CLI de Proxmox (`qm`, `pct`, `pvesm`, `pvesh`). Vous devez impérativement les exécuter en tant que **`root`** dans le shell de votre nœud Proxmox.

---

## ✨ Fonctionnalités

| | Fonctionnalité | Description |
| :---: | --- | --- |
| 🧩 | **100 % autonome** | Aucune dépendance envers des bibliothèques ou des frameworks distants. |
| 💾 | **Cache local intelligent** | Les images Cloud (`.qcow2`, `.img`) sont téléchargées puis mises en cache dans `/var/lib/vz/template/iso/` pour accélérer les déploiements futurs. |
| 🪟 | **Windows automatisé** | Génère une disquette/USB virtuelle avec `autounattend.xml` pour contourner les restrictions matérielles (TPM, Secure Boot, RAM) et injecter les pilotes VirtIO en silence. |
| ⚡ | **Performances optimisées** | Configurations de stockage robustes avec l'option de cache `writeback` et sécurités UEFI/OVMF préconfigurées. |
| 🔧 | **Gestion d'erreurs robuste** | Validation systématique, cleanup automatique en cas d'échec, parsing robuste des volumes disque. |
| 🛡️ | **Sécurité renforcée** | Vérification root, validation des commandes, mot de passe par défaut sécurisé. |
| 📊 | **Messages clairs** | Sorties colorées et informatives pour un suivi facile de l'exécution. |

---

## 📋 Prérequis

- Un nœud **Proxmox VE 7.x, 8.x ou 9.2** opérationnel.
- Un accès **root** au shell du nœud.
- *(VM Windows uniquement)* Votre fichier `.iso` placé dans le stockage **local → ISO Images** de Proxmox.

---

## 🚀 Déploiement

Commencez par cloner le dépôt sur votre nœud Proxmox :

```bash
git clone https://github.com/<votre-utilisateur>/ProxForge.git
cd ProxForge
```

### 🐧 Machines virtuelles Linux

#### Ubuntu

```bash
bash linux/create-ubuntu-vm.sh
```

#### Debian

```bash
bash linux/create-debian-vm.sh
```

#### Fedora

```bash
bash linux/create-fedora-vm.sh
```

#### Kali Linux

```bash
bash linux/create-kali-vm.sh
```

#### Arch Linux

```bash
bash linux/create-arch-linux-vm.sh
```

### 📦 Conteneurs LXC

#### Docker

```bash
bash lxc/create-docker-lxc.sh
```

#### Adblock & DNS

```bash
bash "lxc/Adblock &DNS/create-pihole-lxc.sh"
bash "lxc/Adblock &DNS/create-adguard-lxc.sh"
bash "lxc/Adblock &DNS/create-powerdns-lxc.sh"
bash "lxc/Adblock &DNS/create-technitium-lxc.sh"
```

#### Bases de données

```bash
bash lxc/Databases/create-mariadb-lxc.sh
bash lxc/Databases/create-mongodb-lxc.sh
bash lxc/Databases/create-postgresql-lxc.sh
```

#### Media & Streaming

```bash
bash "lxc/Media &Streaming/create-immich-lxc.sh"
bash "lxc/Media &Streaming/create-jellyfin-lxc.sh"
```

#### Accès à distance & VPN

```bash
bash "lxc/Remote Access &VPN/create-wireguard-lxc.sh"
bash "lxc/Remote Access &VPN/create-Cloudflared-lxc.sh"
bash "lxc/Remote Access &VPN/create-netbird-lxc.sh"
bash "lxc/Remote Access &VPN/create-Tailscale-lxc.sh"
```

### 🪟 Machines virtuelles Windows

> [!NOTE]
> Pour les scripts Windows, assurez-vous d'avoir préalablement placé votre fichier `.iso` dans le stockage **local → ISO Images** de Proxmox.

```bash
bash windows/create-windows11-vm.sh
bash windows/create-win10-vm.sh
bash windows/create-winserver2025-vm.sh
```

### 🛡️ Pare-feux OPNsense

```bash
bash opnsense/create-opnsense-vm.sh
```

---

## 🔧 Personnalisation

Surchargez les variables d'environnement à la volée :

### Pour les VM (`qm`)

```bash
VMID=100 CPU_CORES=8 RAM_SIZE=16384 DISK_SIZE=100G STORAGE=local-zfs bash linux/create-ubuntu-vm.sh
```

### Pour les LXC (`pct`)

```bash
CTID=200 CPU_CORES=4 RAM_SIZE=4096 DISK_SIZE=50G STORAGE=local-lvm bash lxc/create-docker-lxc.sh
```

### Variables générales

| Variable | Description | Valeur par défaut |
| --- | --- | --- |
| `VMID` / `CTID` | Identifiant unique | Incrément automatique (`nextid`) |
| `HN` | Nom de la machine | `<distro>-vm-<id>` ou `<service>-lxc-<id>` |
| `CPU_CORES` | Nombre de vCPUs | `2` (Linux) / `4` (Windows, OPNsense) |
| `RAM_SIZE` | Mémoire vive (Mo) | `2048` (2 Go) |
| `DISK_SIZE` | Taille du disque | `8G` – `20G` selon le service |
| `STORAGE` | Stockage Proxmox | `local-lvm` |
| `BRIDGE` | Pont réseau | `vmbr0` |
| `START_VM` / `START_LXC` | Démarrer après création | `yes` |
| `TEMPLATE_STORAGE` | Stockage des templates | `local` |

### Variables Cloud-Init (Linux)

| Variable | Description | Valeur par défaut |
| --- | --- | --- |
| `CIUSER` | Utilisateur créé | `admin` |
| `CIPASSWORD` | Mot de passe | *Aucun (à configurer)* |
| `SSH_PUBKEY_FILE` | Clé SSH publique | *Aucun* |
| `IPCONFIG0` | Configuration réseau | `ip=dhcp` |

---

## 🔒 Sécurité

> [!WARNING]
> **Comptes par défaut :** Mot de passe temporaire pour Windows, Pi-hole, AdGuard, MariaDB, MongoDB, PostgreSQL et WGDashboard :
>
> ```text
> Proxmox2026!
> ```
>
> **Modifiez-le immédiatement** après la première connexion.

---

## 📝 Changelog

### ✅ Version 1.1.0 (Novembre 2025) — Corrections majeures

#### Améliorations générales (TOUS les scripts)

- ✅ Validation root systématique.
- ✅ Validation des commandes nécessaires.
- ✅ Cleanup automatique en cas d'erreur (`trap`).
- ✅ Parsing robuste (remplace `grep -oP`).
- ✅ Gestion des erreurs améliorée.
- ✅ Messages colorés standardisés.
- ✅ Création automatique des répertoires (`mkdir -p`).

#### Scripts corrigés

- **Linux (5)** : `create-ubuntu-vm.sh`, `create-debian-vm.sh`, `create-kali-vm.sh`, `create-arch-linux-vm.sh`, `create-fedora-vm.sh`.
- **LXC (14)** : Tous les scripts des dossiers Adblock & DNS, Databases, Media & Streaming, Remote Access & VPN.
- **À corriger** : Windows (3), OPNsense (1).

---

## 📜 Licence

**MIT** — Libre d'utiliser, modifier et redistribuer.
