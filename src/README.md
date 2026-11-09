# Runtime ProxForge

Ce répertoire contient l'application modulaire maintenue.

- `proxforge.sh` : implémentation de la CLI ; le lanceur racine `../proxforge.sh` lui délègue l'exécution.
- `core/` : bootstrap, configuration, validation, Image Manager, adaptateur Proxmox, cycle de vie et opérations.
- `distributions/` : modules locaux Fedora et Debian.
- `config/` : paramètres par défaut.
- `profiles/` : profils de ressources VM.
- `schemas/` : contrats JSON.
- `trust/` : registre d'empreintes publiques et emplacement des trousseaux provisionnés localement.

Le bootstrap déduit cette racine depuis son propre emplacement. Ne pas déplacer les sous-répertoires indépendamment.
