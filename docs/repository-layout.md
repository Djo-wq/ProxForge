# Organisation du dépôt

## Arborescence principale

```text
proxmox-scripts/
├── .github/
│   ├── pull_request_template.md
│   └── workflows/
│       └── tests.yml
├── config/
│   └── defaults.json
├── core/
│   ├── bootstrap.sh
│   ├── common.sh
│   ├── config.sh
│   ├── errors.sh
│   ├── image_manager.sh
│   ├── module_loader.sh
│   ├── operations_manager.sh
│   ├── profiles.sh
│   ├── proxmox_adapter.sh
│   ├── validation.sh
│   └── vm_lifecycle.sh
├── distributions/
│   ├── debian/
│   └── fedora/
├── docs/
│   ├── phases/
│   ├── architecture.md
│   ├── testing.md
│   └── phase-10-installation.md / phase-11-final-audit.md
├── profiles/
├── schemas/
├── scripts/
├── tests/
├── trust/
├── proxforge.sh
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## Répertoires conservés pour compatibilité

Les dossiers `linux/`, `windows/`, `lxc/`, `network/` et
`Docker-vm/` contiennent les anciens scripts autonomes. Ils restent à leur
emplacement actuel afin de ne pas casser les chemins utilisés par les personnes
qui les ont déjà clonés ou documentés. Ils sont distincts de la CLI modulaire.

## Pourquoi les composants runtime restent à la racine

L'installateur `scripts/install.sh` copie explicitement les dossiers runtime
et le point d'entrée depuis la racine du dépôt. Plusieurs scripts et tests
résolvent également leur racine à partir de `BASH_SOURCE`. Déplacer
`core/`, `distributions/`, `profiles/`, `config/`, `schemas/` ou
`trust/` sans modifier ces contrats casserait l'installation et les tests.

La règle est donc : organiser la documentation et les métadonnées librement,
mais traiter les chemins runtime comme une interface stable. Tout déplacement
de code doit inclure la mise à jour des chemins, des tests et du paquet installé.
