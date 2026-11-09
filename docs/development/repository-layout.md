# Organisation du dépôt

## Arborescence principale

```text
proxmox-scripts/
├── .github/
│   ├── pull_request_template.md
│   └── workflows/tests.yml
├── config/                 # Configuration par défaut
├── core/                   # Moteur modulaire Bash
├── distributions/          # Modules Fedora et Debian
├── docs/
│   ├── phases/             # Historique des phases 1 à 9
│   ├── architecture.md
│   ├── legacy-scripts.md
│   ├── phase-10-installation.md
│   ├── phase-11-final-audit.md
│   ├── repository-layout.md
│   └── testing.md
├── linux/                  # Anciens scripts autonomes (compatibilité)
├── windows/                # Anciens scripts autonomes (compatibilité)
├── lxc/                    # Anciens scripts autonomes (compatibilité)
├── network/                # Anciens scripts autonomes (compatibilité)
├── Docker-vm/              # Anciens scripts autonomes (compatibilité)
├── profiles/               # Profils VM JSON
├── schemas/                # Schémas JSON
├── scripts/                # Install / uninstall / trust provisioning
├── tests/                  # Tests, fixtures et runner
├── trust/                  # Registre d'empreintes
├── proxforge.sh            # Entrée CLI
├── Makefile                # Cibles help / test / lint / check
├── CONTRIBUTING.md
├── .editorconfig
├── .gitignore
├── LICENSE
└── README.md
```

## Deux ensembles de scripts distincts

### CLI modulaire (chemin recommandé)

Les répertoires `core/`, `distributions/`, `profiles/`, `config/`,
`schemas/`, `trust/` et le fichier `proxforge.sh` forment le moteur courant.
L'installateur `scripts/install.sh` copie explicitement ces chemins dans la
structure système. Leurs emplacements sont donc des interfaces runtime stables.

### Anciens scripts autonomes

Les répertoires `linux/`, `windows/`, `lxc/`, `network/` et
`Docker-vm/` sont conservés à leurs chemins historiques pour ne pas casser
les commandes déjà utilisées ou les liens vers des fichiers. Ils ne sont pas
des modules de la CLI et ne bénéficient pas automatiquement de ses politiques,
de son journal d'opérations ou de sa couverture de tests.

La note [Anciens scripts autonomes](legacy-scripts.md) précise cette séparation.
Les nouveaux développements doivent viser la CLI modulaire, sauf demande
explicite de maintenance de ces scripts.

## Pourquoi les composants runtime restent à la racine

L'installateur `scripts/install.sh` copie explicitement les dossiers runtime
et le point d'entrée depuis la racine du dépôt. Plusieurs composants résolvent
également leurs chemins à partir de `BASH_SOURCE`. Déplacer les dossiers
runtime sans mettre à jour simultanément ces références, l'installateur et les
tests casserait l'installation.

La documentation et les outils de développement peuvent être regroupés librement.
Les chemins runtime doivent en revanche être traités comme une interface
stable et déplacés uniquement dans une migration dédiée avec tests de compatibilité.
