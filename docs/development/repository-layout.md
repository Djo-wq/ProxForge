# Organisation du dépôt

## Arborescence

```text
.
├── .github/                  # CI et modèles GitHub
├── src/                      # Runtime de la CLI modulaire
│   ├── core/                 # Bootstrap, managers et adaptateurs
│   ├── distributions/        # Modules Fedora et Debian
│   ├── config/               # Configuration par défaut
│   ├── profiles/             # Profils de ressources VM
│   ├── schemas/              # Schémas JSON
│   ├── trust/                # Registre d'empreintes
│   └── proxforge.sh          # Implémentation CLI
├── scripts/                  # Installateur, désinstallateur, provisionnement
├── tests/                    # Suite hermétique et fixtures
├── legacy/                   # Scripts autonomes historiques
│   ├── vm/linux/
│   ├── vm/windows/
│   ├── lxc/
│   ├── network/
│   └── docker-vm/
├── docs/
│   ├── architecture/
│   ├── development/
│   ├── legacy/
│   └── phases/
├── proxforge.sh              # Lanceur de compatibilité
├── Makefile
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## Responsabilités

### `src/` — application maintenue

Tout le runtime de la CLI modulaire est regroupé dans `src/`. Les chemins internes sont relatifs à cette racine et le bootstrap la déduit de son propre emplacement. Le lanceur racine reste un point d'entrée stable pour éviter de changer les commandes documentées.

### `scripts/` — opérations de maintenance

Les scripts d'installation, de désinstallation et de provisionnement restent à la racine du dépôt parce qu'ils sont des outils de maintenance du projet, et non des composants du runtime.

### `tests/` — validation hermétique

Les tests restent regroupés dans un répertoire avec un runner commun et des fixtures explicites. Ils ne sont pas lancés sur un véritable cluster Proxmox.

### `legacy/` — scripts historiques

Les anciens scripts sont triés par type de ressource et domaine. Ils restent isolés du code maintenu pour ne pas confondre les scripts autonomes avec les modules de la CLI.

### `docs/` — documentation

Les guides sont organisés par sujet. Les rapports des phases 1 à 11 sont regroupés dans `docs/phases/`.

## Règles d'organisation

- Toute nouvelle fonctionnalité de la CLI doit être placée dans `src/` et accompagnée de tests hermétiques.
- Les modules de distribution doivent rester sous `src/distributions/<id>/`.
- Les scripts historiques ne doivent pas être ajoutés à `src/`.
- L'installateur doit copier le lanceur et le dossier `src/` comme un ensemble.
- Toute modification de la structure doit être accompagnée d'une mise à jour de la documentation et de la CI.
