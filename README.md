<div align="center">

```text
██████╗ ██████╗  ██████╗ ██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
███████║██████╔╝██║   ██║ ╚███╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗  
██║     ██╔══██║██║   ██║ ██╔██╗ ██╔══╝  ██║   ██║██╔══██║██║   ██║██╔══╝  
██║     ██║  ██║╚██████╔╝██╔╝ ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
```

**⚡ Créez et gérez des machines virtuelles Linux sur Proxmox VE avec des commandes Bash simples.**

![Bash](https://img.shields.io/badge/langage-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Proxmox VE](https://img.shields.io/badge/Proxmox_VE-9.2%2B-E57000?style=for-the-badge&logo=proxmox&logoColor=white)
![Modules](https://img.shields.io/badge/modules-Fedora%20%7C%20Debian-3776AB?style=for-the-badge)
![Licence](https://img.shields.io/badge/licence-MIT-212121?style=for-the-badge)

</div>

---

## 📚 Sommaire

- [📌 À propos](#à-propos)
- [✨ Fonctionnalités](#fonctionnalités)
- [📋 Prérequis](#prérequis)
- [🗂️ Structure du projet](#structure-du-projet)
- [🚀 Installation](#installation)
- [🖥️ Utilisation](#utilisation)
- [🔧 Personnalisation](#personnalisation)
- [🔒 Sécurité](#sécurité)
- [🧪 Tests](#tests)
- [📜 Licence](#licence)

---

## À propos

**ProxForge** est un outil écrit en Bash pour automatiser la création de machines virtuelles sur **Proxmox VE 9.2+**.

La version actuelle propose une commande principale, appelée CLI, qui permet de choisir une distribution Linux, de consulter les versions disponibles, de vérifier les images et de lancer la création d'une VM.

Deux distributions sont actuellement prises en charge par cette CLI :

- **Fedora**
- **Debian**

Le dépôt contient aussi d'anciens scripts pour Windows, LXC, le réseau et Docker. Ils sont rangés dans le dossier `legacy/` pour les garder séparés du nouvel outil.

> [!IMPORTANT]
> Pour les nouveaux déploiements, il est conseillé d'utiliser la CLI `proxforge`. Les anciens scripts de `legacy/` sont conservés à part et ne bénéficient pas des mêmes tests ni des mêmes contrôles.

---

## Fonctionnalités

| | Fonctionnalité | Explication |
| :---: | --- | --- |
| 🐧 | **VM Linux** | Crée des machines virtuelles Fedora ou Debian. |
| 💿 | **Vérification des images** | Vérifie les fichiers téléchargés avant de les utiliser. |
| ⚙️ | **Profils prêts à l'emploi** | Propose plusieurs profils pour choisir les ressources de la VM. |
| 🧰 | **Commandes de contrôle** | Affiche les informations sur Proxmox, les modules, les profils et les opérations. |
| 📝 | **Suivi des opérations** | Garde des informations sur les opérations lancées avec ProxForge. |
| 📦 | **Anciens scripts conservés** | Garde les scripts Windows, LXC, réseau et Docker dans `legacy/`. |

---

## Prérequis

Pour installer et utiliser la CLI sur un serveur :

- Un serveur **Proxmox VE 9.2+** basé sur **Debian 13**.
- Un accès au terminal du serveur.
- Les droits **root** pour installer ProxForge.
- Les outils nécessaires à ProxForge, notamment `bash`, `jq` et les commandes Proxmox.

Pour consulter le code et lancer les tests, un ordinateur avec Bash et `jq` suffit. ShellCheck est également nécessaire pour le contrôle du code.

---

## Structure du projet

Les fichiers sont rangés par rôle pour que l'on sache facilement où trouver le code.

```text
ProxForge/
├── src/                       # Code principal de ProxForge
│   ├── core/                  # Fonctionnement interne de l'outil
│   ├── distributions/         # Modules Fedora et Debian
│   ├── config/                # Configuration par défaut
│   ├── profiles/              # Profils des machines virtuelles
│   ├── schemas/               # Règles de vérification des fichiers JSON
│   ├── trust/                 # Clés et empreintes de confiance
│   └── proxforge.sh           # Programme principal
├── scripts/                   # Installation et désinstallation
├── tests/                     # Tests automatiques
├── legacy/                    # Anciens scripts indépendants
│   ├── vm/
│   │   ├── linux/
│   │   └── windows/
│   ├── lxc/
│   ├── network/
│   └── docker-vm/
├── docs/                      # Documentation
├── proxforge.sh               # Commande de lancement
├── Makefile                   # Commandes de test
├── CONTRIBUTING.md            # Guide pour contribuer
└── LICENSE                    # Licence MIT
```

---

## Installation

Commencez par récupérer le dépôt :

```bash
git clone https://github.com/Djo-wq/ProxForge.git
cd ProxForge
```

Depuis le shell de votre serveur Proxmox, exécutez l'installation en tant que root
(la session Shell Proxmox est généralement déjà ouverte avec ce compte) :

```bash
bash scripts/install.sh
```

Pour installer explicitement les dépendances Debian manquantes :

```bash
bash scripts/install.sh --install-dependencies
```

Le trousseau public Fedora peut être provisionné séparément :

```bash
bash scripts/install.sh --provision-fedora-keyring
```

Si vous lancez ces commandes depuis un compte non-root disposant de `sudo`,
préfixez chacune d'elles par `sudo`.

Le provisionnement du trousseau est nécessaire avant le premier déploiement Fedora.
Il n'est pas nécessaire pour Debian. Si ProxForge est déjà installé, vous pouvez
provisionner les clés avec :

```bash
/usr/local/lib/proxforge/scripts/provision-fedora-keyring.sh
```

La validation du trousseau est liée aux empreintes épinglées dans le dépôt.

---

## Utilisation

Une fois installé, la commande `proxforge` est disponible dans le terminal.

### Voir l'aide

```bash
proxforge --help
```

### Voir les distributions disponibles

```bash
proxforge module list
```

### Voir les versions de Fedora ou Debian

```bash
proxforge module releases fedora
proxforge module releases debian
```

### Vérifier un module

```bash
proxforge module validate fedora
proxforge module validate debian
```

### Voir les profils disponibles

```bash
proxforge profile list
```

### Vérifier le serveur Proxmox

```bash
proxforge doctor
proxforge pve doctor
proxforge pve nodes
proxforge pve storages
proxforge pve bridges
```

### Créer une machine virtuelle

Exemple pour créer une VM Fedora avec le profil `standard` :

```bash
proxforge deploy fedora stable standard local-lvm vmbr0 --name fedora-lab --vmid auto
```

> [!WARNING]
> La commande `deploy` crée réellement une machine virtuelle sur votre serveur Proxmox. Vérifiez le stockage, le réseau et les ressources disponibles avant de la lancer. Pour les premiers essais, utilisez un serveur de test.

Pour un déploiement Debian, le checksum officiel est vérifié via HTTPS. Cette
méthode est désactivée par défaut. Pour un essai ponctuel, conservez la
configuration système inchangée et créez un fichier d'override dédié :

```bash
cat > /root/proxforge-debian-test.json <<'JSON'
{"allow_official_tls_checksum":true}
JSON
chmod 0600 /root/proxforge-debian-test.json
proxforge --config /root/proxforge-debian-test.json config validate
proxforge --config /root/proxforge-debian-test.json module image debian latest
```

Pour un déploiement de test explicitement autorisé, passez le même fichier
avec la commande `deploy` :

```bash
proxforge --config /root/proxforge-debian-test.json deploy debian latest standard local-lvm vmbr0 --name proxforge-debian-test --vmid auto
```

Cette option reconnaît la confiance dans le checksum reçu via TLS ; elle ne
constitue pas une signature OpenPGP détachée. Ne l'activez que si cette politique
correspond à votre exigence de sécurité. Supprimez le fichier d'override après
les essais.

---

## Personnalisation

ProxForge utilise des profils pour définir les ressources des machines virtuelles.

Le champ `disk_gb` définit une taille minimale pour le disque système : ProxForge agrandit le disque importé si nécessaire et ne le réduit jamais si l'image source est déjà plus grande.

Vous pouvez consulter les profils fournis :

```bash
proxforge profile list
proxforge profile show standard
```

La configuration de l'installation se trouve dans :

```text
/etc/proxforge/config.json
```

Les valeurs de départ fournies avec le projet se trouvent dans `src/config/defaults.json`.

---

## Sécurité

Quelques règles importantes :

- Vérifiez toujours le stockage et le réseau avant de créer une VM.
- Commencez par les commandes d'inspection avant de lancer un déploiement.
- La commande `deploy` crée une ressource sur Proxmox.
- Les commandes de retour arrière et de désinstallation peuvent modifier ou supprimer des ressources.
- Les scripts de `legacy/` sont anciens : vérifiez-les individuellement avant de les utiliser.

Les tests automatiques n'installent rien sur un vrai serveur Proxmox et ne créent aucune VM. Ils vérifient le fonctionnement du code dans un environnement de test.

---

## Tests

Pour vérifier le projet, placez-vous à la racine du dépôt puis lancez :

```bash
make check
```

Pour vérifier uniquement la syntaxe des scripts Bash :

```bash
make syntax
```

Les scripts de `legacy/` sont uniquement contrôlés pour vérifier leur syntaxe. Ils ne sont pas exécutés par les tests.

---

## Documentation

Pour plus d'informations :

- [Architecture du projet](docs/architecture/overview.md)
- [Organisation des fichiers](docs/development/repository-layout.md)
- [Installation et tests](docs/development/testing.md)
- [Anciens scripts](docs/legacy/README.md)
- [Historique des phases](docs/README.md)
- [Guide de contribution](CONTRIBUTING.md)

---

## Licence

Ce projet est distribué sous licence **MIT**. Vous pouvez l'utiliser, le modifier et le partager, dans le respect de cette licence.
