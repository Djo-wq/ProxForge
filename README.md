# ProxForge

**CLI Bash modulaire pour préparer et gérer des machines virtuelles Linux sur Proxmox VE.**

ProxForge regroupe un moteur modulaire, des modules de distributions, un gestionnaire d'images, un adaptateur Proxmox et un journal d'opérations. Les scripts historiques autonomes sont conservés séparément dans `legacy/`.

## État du projet

- CLI et Core modulaires : phases 1 à 11 intégrées dans `main`.
- Modules actuellement présents : Fedora et Debian.
- Cible : Proxmox VE 9.2 ou plus récent, sur Debian 13.
- Tests automatisés : suite hermétique, contrôle syntaxique Bash et ShellCheck via GitHub Actions.
- Validation sur un véritable nœud Proxmox : à effectuer séparément avant toute utilisation en production.

## Démarrage rapide

### Cloner le dépôt

```bash
git clone https://github.com/Djo-wq/proxmox-scripts.git
cd proxmox-scripts
```

### Lire l'aide et exécuter les contrôles

Sur une machine de développement disposant de Bash, `jq` et ShellCheck :

```bash
bash proxforge.sh --help
make check
```

### Installer sur un nœud de test Proxmox

L'installation système est destinée à Proxmox VE 9.x sur Debian 13 et doit être exécutée en tant que root :

```bash
sudo bash scripts/install.sh
```

Pour autoriser l'installation des dépendances Debian documentées :

```bash
sudo bash scripts/install.sh --install-dependencies
```

Le provisionnement du trousseau public Fedora est une étape séparée et explicite :

```bash
sudo bash scripts/install.sh --provision-fedora-keyring
```

Sans cette option, aucun téléchargement de trousseau n'est effectué.

## Utiliser la CLI

Quelques commandes d'inspection :

```bash
proxforge --version
proxforge doctor
proxforge module list
proxforge module show fedora
proxforge module releases debian
proxforge module validate fedora
proxforge module validate debian
proxforge profile list
proxforge config show
proxforge pve doctor
proxforge pve nodes
proxforge pve storages
proxforge pve bridges
```

Les commandes d'inspection ne doivent pas créer de VM. La commande `deploy` crée réellement une ressource Proxmox :

```bash
proxforge deploy fedora stable standard local-lvm vmbr0 --name fedora-lab --vmid auto
```

N'exécuter cette commande que sur un nœud de test, avec un stockage, un bridge et une capacité réservés aux essais.

La configuration persistante est installée sous `/etc/proxforge/config.json`. Les valeurs par défaut du dépôt sont dans `src/config/defaults.json`. Le mode Debian reposant sur un checksum officiel obtenu par TLS reste désactivé par défaut.

## Structure du dépôt

```text
.
├── .github/                 # CI et modèles GitHub
├── src/                     # Application ProxForge maintenue
│   ├── core/                # Bootstrap, managers et adaptateurs
│   ├── distributions/       # Modules Fedora et Debian
│   ├── config/              # Configuration par défaut
│   ├── profiles/            # Profils VM
│   ├── schemas/             # Contrats JSON
│   ├── trust/               # Registre d'empreintes de confiance
│   └── proxforge.sh         # Implémentation de la CLI
├── scripts/                 # Installation, désinstallation, clés
├── tests/                   # Tests hermétiques et fixtures
├── legacy/                  # Scripts autonomes historiques
│   ├── vm/linux/
│   ├── vm/windows/
│   ├── lxc/
│   ├── network/
│   └── docker-vm/
├── docs/                    # Architecture, développement et phases
├── proxforge.sh             # Lanceur stable vers src/proxforge.sh
├── Makefile
├── CONTRIBUTING.md
└── LICENSE
```

Le moteur maintenu est regroupé sous `src/`. Le fichier `proxforge.sh` à la racine est conservé comme point d'entrée stable pour les utilisateurs et les scripts existants. Les scripts autonomes sont archivés sous `legacy/` et ne font pas partie du runtime modulaire.

## Installation et données

L'installateur prépare les répertoires suivants :

- `/usr/local/lib/proxforge` : application complète, dont `src/` ;
- `/usr/local/bin/proxforge` : lien vers le lanceur ;
- `/etc/proxforge` : configuration ;
- `/var/lib/proxforge` : cache, temporaires et état ;
- `/var/log/proxforge` : journaux.

La désinstallation conserve la configuration et les données par défaut :

```bash
sudo bash /usr/local/lib/proxforge/scripts/uninstall.sh
```

La suppression de la configuration ou des données nécessite les options explicites `--remove-config` et `--remove-data`.

## Documentation

- [Index de la documentation](docs/README.md)
- [Architecture](docs/architecture/overview.md)
- [Organisation du dépôt](docs/development/repository-layout.md)
- [Tests et pré-vol](docs/development/testing.md)
- [Anciens scripts](docs/legacy/README.md)
- [Phase 10 — Installation](docs/phases/phase-10-installation.md)
- [Phase 11 — Audit final](docs/phases/phase-11-final-audit.md)
- [Guide de contribution](CONTRIBUTING.md)

## Sécurité et limites

Les commandes `deploy`, `operation rollback` et les opérations de désinstallation ou de nettoyage peuvent modifier des ressources. Vérifier les identifiants, la propriété des ressources, le stockage et l'état du cluster avant toute mutation.

La CI utilise des tests hermétiques et des commandes simulées. Elle ne certifie pas le comportement sur un serveur Proxmox réel. La première validation doit être faite sur un nœud de test dédié, en commençant par les commandes d'inspection.

Consulter [les étapes de pré-vol](docs/development/testing.md) avant le premier déploiement.

## Licence

Voir [LICENSE](LICENSE).
