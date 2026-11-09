# Contribuer à ProxForge

Merci de contribuer à ProxForge. Le dépôt contient deux ensembles distincts :
la CLI modulaire actuelle et une ancienne collection de scripts autonomes
conservée pour référence. Les nouvelles fonctionnalités doivent viser la CLI
modulaire, sauf demande explicite de maintenance d'un ancien script.

## Avant de modifier le code

1. Ouvrir une branche dédiée depuis `main` : `feat/<sujet>`,
   `fix/<sujet>` ou `chore/<sujet>`.
2. Lire [l'architecture](docs/architecture/overview.md), [l'organisation du dépôt](docs/development/repository-layout.md)
   et [les instructions de test](docs/development/testing.md).
3. Identifier les chemins runtime. L'installateur copie explicitement
   `proxforge.sh`, `src/` et `scripts/`. Les déplacer exige de mettre à jour
   l'installateur, les tests et la documentation dans le même changement.

## Conventions Bash

- Utiliser `#!/usr/bin/env bash` et `set -Eeuo pipefail` pour les nouveaux
  scripts d'administration.
- Garder les arguments entre guillemets et préférer les tableaux Bash pour
  construire des commandes.
- Éviter `eval`, les téléchargements exécutés directement et les chemins
  construits à partir d'une entrée non validée.
- Envoyer les diagnostics sur stderr ; préserver stdout pour les données
  structurées des fonctions de contrat.
- Valider les entrées avant toute mutation Proxmox.
- Ne jamais supposer qu'une ressource Proxmox appartient à ProxForge sans
  preuve issue du manifeste et de l'inventaire.
- Ne pas introduire de secrets, de clé privée ou de trousseau local dans Git.

## Tests requis

Avant une PR, lancer :

```bash
bash tests/run-tests.sh
make check
```

Les tests doivent rester hermétiques : ils ne doivent ni créer/supprimer une VM
réelle, ni libérer un volume, ni dépendre du réseau public. Toute validation
réelle sur Proxmox doit être décrite séparément comme une procédure manuelle et
ne remplace pas les tests automatisés.

## Pull Request

Une PR doit expliquer :
- le problème et le comportement attendu ;
- les chemins et composants modifiés ;
- les tests exécutés et leur résultat ;
- les changements de sécurité ou de compatibilité ;
- les validations manuelles qui restent nécessaires.

Ne pas fusionner directement dans `main` depuis une branche de travail.
