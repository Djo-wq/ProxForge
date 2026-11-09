# Architecture de ProxForge

## Vue d'ensemble

La version actuelle est une CLI Bash modulaire. `proxforge.sh` est le point
d'entrée et délègue les responsabilités à `core/`. Les distributions livrent
des modules locaux versionnés ; elles ne sont pas téléchargées comme du code
exécutable et ne sont pas isolées dans un sandbox.

## Composants

| Répertoire / fichier | Responsabilité |
| --- | --- |
| `proxforge.sh` | Options globales, commandes CLI, complétion Bash |
| `core/` | Bootstrap, configuration, validation, contrats, cache, adaptateur Proxmox et cycle de vie |
| `distributions/<id>/` | Métadonnées, versions publiées et descripteurs d'images par distribution |
| `profiles/` | Profils de ressources VM au format JSON |
| `config/defaults.json` | Valeurs de configuration par défaut |
| `schemas/` | Contrats JSON de configuration, modules, profils, images et opérations |
| `trust/` | Registre des empreintes de clés de confiance ; le matériel de clé provisionné localement n'est pas versionné |
| `scripts/` | Installation, désinstallation et provisionnement du trousseau Fedora |
| `tests/` | Tests hermétiques, fixtures et runner commun |
| `docs/` | Guides opérateur, architecture et historique des phases |

## Flux de déploiement

1. La CLI valide les arguments et charge la configuration.
2. Le chargeur sélectionne un module de distribution local et valide son contrat.
3. Le module résout la version demandée et décrit l'image attendue.
4. L'Image Manager acquiert l'image via HTTPS, suit les redirections autorisées,
   vérifie le checksum et la signature selon la politique du module, puis gère
   le cache.
5. Le VM Lifecycle Manager coordonne l'opération.
6. Le Proxmox Adapter effectue les lectures et mutations nécessaires via les
   commandes Proxmox.
7. L'Operations Manager conserve le journal et le manifeste nécessaires à la
   réconciliation et aux suppressions dont la propriété a été établie.

La création d'une VM est explicite : les commandes d'inspection ne doivent pas
déclencher de mutation. La commande `deploy` crée une ressource Proxmox et doit
être traitée comme une opération réelle, pas comme une commande de diagnostic.

## Configuration et données

La configuration persistante est installée sous `/etc/proxforge/config.json`.
Les valeurs par défaut du dépôt sont dans `config/defaults.json`. Le cache
d'images, les temporaires et l'état utilisent par défaut
`/var/lib/proxforge/`; les journaux utilisent `/var/log/proxforge/`.

La politique Debian pour un checksum officiel obtenu par TLS reste désactivée
par défaut. Le provisionnement du trousseau Fedora est une étape explicite.

## Séparation avec les anciens scripts

Les répertoires racine `linux/`, `windows/`, `lxc/`, `network/` et
`Docker-vm/` contiennent une collection historique de scripts autonomes.
Ils ne sont pas les modules de distribution de la CLI et ne passent pas par
l'ensemble des contrôles du cycle de vie modulaire. Leur présence ne signifie
pas qu'ils sont couverts par les mêmes tests ou garanties. La CLI modulaire est
le chemin recommandé pour les nouveaux déploiements.

## Contrats importants

- Les modules de distribution sont du code Bash local de confiance.
- Les sorties structurées des fonctions de contrat sont transportées dans les
  variables de résultat convenues et validées avec `jq`.
- Les identifiants d'opération, les manifestes et les événements doivent rester
  liés et validés avant toute reprise ou suppression.
- L'Image Manager ne doit pas publier une entrée de cache non vérifiée.
- Les chemins d'installation gérés ne doivent pas écraser des fichiers
  étrangers à ProxForge.
