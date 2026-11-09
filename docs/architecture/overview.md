# Architecture de ProxForge

## Vue d'ensemble

ProxForge est une CLI Bash modulaire. Le lanceur `proxforge.sh` à la racine délègue à l'implémentation `src/proxforge.sh`, qui charge les composants de `src/core/`. Les modules de distributions résident dans `src/distributions/`.

## Composants

| Chemin | Responsabilité |
| --- | --- |
| `proxforge.sh` | Lanceur stable vers l'implémentation CLI |
| `src/proxforge.sh` | Options globales, commandes CLI et complétion Bash |
| `src/core/` | Bootstrap, configuration, validation, contrats, cache, adaptateur Proxmox et cycle de vie |
| `src/distributions/<id>/` | Métadonnées, versions publiées et descripteurs d'images |
| `src/profiles/` | Profils de ressources VM au format JSON |
| `src/config/defaults.json` | Valeurs de configuration par défaut |
| `src/schemas/` | Contrats JSON de configuration, modules, profils, images et opérations |
| `src/trust/` | Registre d'empreintes de confiance |
| `scripts/` | Installation, désinstallation et provisionnement du trousseau Fedora |
| `tests/` | Tests hermétiques, fixtures et runner commun |
| `legacy/` | Scripts autonomes historiques, hors runtime modulaire |
| `docs/` | Guides opérateur, architecture et historique des phases |

## Flux de déploiement

1. Le lanceur stable appelle l'implémentation de la CLI.
2. La CLI valide les arguments et charge la configuration.
3. Le chargeur sélectionne un module de distribution local et valide son contrat.
4. Le module résout la version demandée et décrit l'image attendue.
5. L'Image Manager acquiert l'image via HTTPS, vérifie le checksum et la signature selon la politique du module, puis gère le cache.
6. Le VM Lifecycle Manager coordonne l'opération.
7. Le Proxmox Adapter effectue les lectures et mutations nécessaires via les commandes Proxmox.
8. L'Operations Manager conserve le journal et le manifeste nécessaires à la réconciliation.

La création d'une VM est explicite : les commandes d'inspection ne déclenchent pas de mutation. La commande `deploy` crée une ressource Proxmox et doit être traitée comme une opération réelle.

## Configuration et données

La configuration persistante est installée sous `/etc/proxforge/config.json`. Les valeurs par défaut du dépôt sont dans `src/config/defaults.json`. Le cache d'images, les temporaires et l'état utilisent par défaut `/var/lib/proxforge/` ; les journaux utilisent `/var/log/proxforge/`.

La politique Debian pour un checksum officiel obtenu par TLS reste désactivée par défaut. Le provisionnement du trousseau Fedora est une étape explicite.

## Séparation avec les anciens scripts

`legacy/` contient une collection historique de scripts autonomes pour les VM Linux, les VM Windows, les conteneurs LXC, le réseau et Docker. Ils ne sont pas les modules de distribution de la CLI et ne passent pas automatiquement par l'Image Manager, le VM Lifecycle Manager ou l'Operations Manager. Ils ne bénéficient pas des mêmes garanties de tests. La CLI modulaire est le chemin recommandé pour les nouveaux déploiements.

## Contrats importants

- Les modules de distribution sont du code Bash local de confiance.
- Les sorties structurées des fonctions de contrat sont validées avec `jq`.
- Les identifiants d'opération, manifestes et événements doivent rester liés et validés avant toute reprise ou suppression.
- L'Image Manager ne doit pas publier une entrée de cache non vérifiée.
- Les chemins d'installation gérés ne doivent pas écraser des fichiers étrangers à ProxForge.
