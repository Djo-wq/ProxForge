<div align="center">

```text
██████╗ ██████╗  ██████╗ ██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
███████║██████╔╝██║   ██║ ╚███╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗  
██║     ██╔══██║██║   ██║ ██╔██╗ ██╔══╝  ██║   ██║██╔══██║██║   ██║██╔══╝  
██║     ██║  ██║╚██████╔╝██╔╝ ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
```

**⚡ Déployez des machines virtuelles Linux et Windows, des pare-feux OPNsense et des conteneurs Docker sur Proxmox VE : entièrement automatisé, optimisé et sans dépendance externe.**

```bash
$ ssh root@proxmox
$ ./proxforge --deploy <linux|windows|opnsense|docker>
```

![Bash](https://img.shields.io/badge/langage-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Proxmox VE](https://img.shields.io/badge/Proxmox_VE-7.x%20%7C%208.x-E57000?style=for-the-badge&logo=proxmox&logoColor=white)
![Zéro dépendance](https://img.shields.io/badge/z%C3%A9ro_d%C3%A9pendance-00C853?style=for-the-badge)
![Licence](https://img.shields.io/badge/licence-MIT-212121?style=for-the-badge)

</div>

---

## 📚 Sommaire

- [📌 À propos](#à-propos)
- [✨ Fonctionnalités](#fonctionnalités)
- [📋 Prérequis](#prérequis)
- [🚀 Déploiement](#déploiement)
- [🔧 Personnalisation](#personnalisation)
- [🔒 Sécurité](#sécurité)
- [📜 Licence](#licence)

---

## À propos

ProxForge est une collection de **scripts Bash autonomes (standalone)** conçus spécifiquement pour **Proxmox VE 7.x / 8.x**.

Contrairement aux solutions qui reposent sur des frameworks externes, ProxForge automatise l'intégralité du cycle de déploiement **directement depuis le shell de votre nœud Proxmox** : aucune infrastructure supplémentaire, aucun agent, aucune configuration complexe.

> [!IMPORTANT]
> Les scripts interagissent directement avec l'API CLI de Proxmox (`qm`, `pct`, `pvesm`, `pvesh`). Vous devez impérativement les exécuter en tant que **`root`** dans le shell de votre nœud Proxmox.

---

## Fonctionnalités

| | Fonctionnalité | Description |
| :---: | --- | --- |
| 🧩 | **100 % autonome** | Aucune dépendance envers des bibliothèques ou des frameworks distants. |
| 💾 | **Cache local intelligent** | Les images Cloud (`.qcow2`, `.img`) sont téléchargées puis mises en cache dans `/var/lib/vz/template/iso/` pour accélérer les déploiements futurs. |
| 🪟 | **Windows automatisé** | Génère une disquette/USB virtuelle avec `autounattend.xml` pour contourner les restrictions matérielles (TPM, Secure Boot, RAM) et injecter les pilotes VirtIO en silence. |
| ⚡ | **Performances optimisées** | Configurations de stockage robustes avec l'option de cache `writeback` et sécurités UEFI/OVMF préconfigurées. |

---

## Prérequis

- Un nœud **Proxmox VE 7.x ou 8.x** opérationnel.
- Un accès **root** au shell du nœud.
- *(VM Windows uniquement)* votre fichier `.iso` placé dans le stockage Proxmox (voir la note Windows dans la section [Déploiement](#déploiement)).

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

---

## Sécurité

> [!WARNING]
> **Comptes Windows automatisés** : les scripts de déploiement Windows créent par défaut un compte administrateur local sécurisé avec le mot de passe temporaire :
>
> ```
> Proxmox2026!
> ```
>
> Veillez à **modifier ce mot de passe immédiatement** après votre première connexion au bureau.

---

## Licence

Ce projet est distribué sous licence **MIT**. Vous êtes libre de l'utiliser, de le modifier et de le redistribuer, à des fins personnelles comme commerciales.
