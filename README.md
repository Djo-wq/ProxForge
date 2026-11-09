# ProxForge

**CLI Bash modulaire pour préparer et gérer des machines virtuelles Linux sur Proxmox VE.**

ProxForge regroupe un moteur de déploiement modulaire, des modules de distributions,
un gestionnaire d'images, un adaptateur Proxmox et un journal d'opérations. Le dépôt
conserve aussi une collection historique de scripts autonomes ; elle est distincte
de la CLI actuelle.

> **Chemin recommandé :** utiliser `proxforge.sh` et ses modules locaux dans
> `distributions/` pour les nouveaux déploiements. Les scripts historiques de
> `linux/`, `windows/`, `lxc/`, `network/` et `Docker-vm/` ne partagent pas
> automatiquement les mêmes garanties ni la même couverture de tests.

## État du projet

- CLI et Core modulaires : phases 1 à 11 intégrées dans `main`.
- Modules actuellement présents : Fedora et Debian.
- Cible de l'adaptateur : Proxmox VE 9.2 ou plus récent, sur Debian 13.
- Tests automatisés : suite hermétique et ShellCheck via GitHub Actions.
- Validation sur un véritable nœud Proxmox : à effectuer séparément avant utilisation en production.

## Démarrage rapide

### 1. Cloner le dépôt

```bash
git clone https://github.com/Djo-wq/proxmox-scripts.git
cd proxmox-scripts
```

### 2. Lire l'aide et exécuter les tests

Sur une machine de développement disposant de Bash et `jq` :

```bash
./proxforge.sh --help
bash tests/run-tests.sh
```

Pour les contrôles ShellCheck :

```bash
shellcheck --severity=error proxforge.sh scripts/install.sh scripts/uninstall.sh tests/test-install.sh
```

### 3. Installer sur un nœud de test Proxmox

L'installation système est destinée à Proxmox VE 9.x sur Debian 13 et doit être
exécutée en tant que root :

```bash
sudo bash scripts/install.sh
```

Pour autoriser l'installation des dépendances Debian documentées :

```bash
sudo bash scripts/install.sh --install-dependencies
```

Cette option installe les dépendances utilisateur manquantes. Elle ne remplace
pas et n'installe pas les commandes spécifiques à Proxmox.

Le provisionnement du trousseau public Fedora est volontairement séparé :

```bash
sudo bash scripts/install.sh --provision-fedora-keyring
```

Cette option télécharge la collection de clés publiques Fedora et vérifie les
empreintes attendues par le registre versionné. Sans cette option, aucun
téléchargement de trousseau n'est effectué.

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

Les commandes d'inspection ne doivent pas créer de VM. La commande `deploy`
est une opération réelle qui demande un stockage et un bridge valides et qui
crée une ressource Proxmox :

```bash
proxforge deploy fedora stable standard local-lvm vmbr0 --name fedora-lab --vmid auto
```

N'exécuter cette commande que sur un nœud de test, avec un stockage, un bridge
et une capacité réservés aux essais. Vérifier l'inventaire et la configuration
avant toute mutation.

La configuration persistante est installée sous
`/etc/proxforge/config.json`. Les valeurs par défaut sont versionnées dans
`config/defaults.json`. Le mode Debian reposant sur un checksum officiel obtenu
par TLS reste désactivé par défaut ; ne l'activer que si cette politique de
confiance est comprise et acceptée.

## Architecture

| Chemin | Rôle |
| --- | --- |
| `proxforge.sh` | Entrée CLI, options globales et complétion Bash |
| `core/` | Configuration, validation, contrats, image manager, adaptateur Proxmox et cycle de vie |
| `distributions/` | Modules locaux Fedora et Debian |
| `profiles/` | Profils de ressources VM |
| `config/` | Configuration par défaut |
| `schemas/` | Schémas JSON versionnés |
| `trust/` | Registre d'empreintes de confiance ; aucun trousseau privé |
| `scripts/` | Installation, désinstallation et provisionnement des clés Fedora |
| `tests/` | Tests hermétiques, fixtures et runner |
| `docs/` | Documentation opérateur et développeur |
| `linux/`, `windows/`, `lxc/`, `network/`, `Docker-vm/` | Scripts autonomes historiques, conservés à leurs chemins existants |

Les chemins du moteur sont utilisés par l'installateur et par les tests. Ne pas
déplacer `core/`, `distributions/`, `profiles/`, `config/`, `schemas/` ou
`trust/` sans mettre à jour leurs références runtime, l'installateur et les
tests dans le même changement.

## Installation, désinstallation et données

L'installateur prépare les fichiers et les répertoires standard :

- `/usr/local/lib/proxforge` : application ;
- `/usr/local/bin/proxforge` : entrée CLI ;
- `/etc/proxforge` : configuration ;
- `/var/lib/proxforge` : cache, temporaires et état ;
- `/var/log/proxforge` : journaux.

La désinstallation conserve la configuration et les données par défaut :

```bash
sudo bash /usr/local/lib/proxforge/scripts/uninstall.sh
```

La suppression de la configuration ou des données nécessite les options
explicites `--remove-config` et `--remove-data`. La configuration est
sauvegardée avant sa suppression.

## Documentation

- [Index de la documentation](docs/README.md)
- [Architecture technique](docs/architecture.md)
- [Organisation du dépôt](docs/repository-layout.md)
- [Installation et désinstallation](docs/phase-10-installation.md)
- [Stratégie de test et pré-vol](docs/testing.md)
- [Référence de la CLI](docs/phases/phase-9-complete-cli.md)
- [Contrats de modules](docs/phases/phase-1-contracts.md)
- [Audit final Phase 11](docs/phase-11-final-audit.md)
- [Anciens scripts autonomes](docs/legacy-scripts.md)
- [Guide de contribution](CONTRIBUTING.md)

## Sécurité et limites

Les commandes `deploy`, `operation rollback` et les opérations de
désinstallation ou de nettoyage peuvent modifier des ressources. Les exécuter
uniquement après vérification des identifiants, de la propriété des ressources,
du stockage et de l'état du cluster.

La CI utilise des tests hermétiques avec des commandes simulées. Elle ne prouve
pas le bon fonctionnement d'une installation sur un serveur Proxmox réel. La
première validation doit être faite sur un nœud de test dédié, en commençant
par les commandes d'inspection et en documentant séparément chaque mutation.

Consulter [les étapes de pré-vol](docs/testing.md) avant le premier déploiement.

## Licence

Voir [LICENSE](LICENSE).
