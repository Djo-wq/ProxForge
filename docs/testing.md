# Tests et préparation à une première validation

## Tests automatisés

Depuis la racine du dépôt :

```bash
bash tests/run-tests.sh
```

Dépendances principales du runner : Bash 5.1 ou supérieur et `jq`.
ShellCheck est utilisé par GitHub Actions pour les scripts d'entrée,
d'installation, de désinstallation et le test d'installation :

```bash
shellcheck --severity=error proxforge.sh scripts/install.sh scripts/uninstall.sh tests/test-install.sh
```

Le runner vérifie aussi la syntaxe Bash des scripts inclus, les schémas JSON,
les contrats des modules, la configuration, les fonctions du Core, le cache
d'images, l'adaptateur Proxmox, le cycle de vie VM et le journal des opérations.

## Ce que les tests ne font pas

La suite automatisée est hermétique. Elle utilise des commandes simulées et
des fichiers temporaires. Elle ne prouve pas qu'une installation réelle sur
un nœud Proxmox est réussie. Elle ne crée/supprime pas de VM réelle, ne libère
pas de volume réel et ne valide pas le comportement d'un stockage ou d'un
bridge physique.

La CI verte signifie que les contrôles automatisés définis dans le dépôt sont
passés ; ce n'est pas une certification d'une installation de production.

## Pré-vol recommandé avant un déploiement réel

Sur une machine de développement, cloner le dépôt et lancer les tests
automatisés. Pour vérifier le processus d'installation sans modifier les
répertoires système, utiliser un préfixe de staging temporaire :

```bash
STAGE_DIR=$(mktemp -d)
bash scripts/install.sh --prefix "$STAGE_DIR"
bash scripts/uninstall.sh --prefix "$STAGE_DIR"
rm -rf -- "$STAGE_DIR"
```

Sur un nœud de test Proxmox VE 9.x / Debian 13 dédié, commencer par les
commandes d'inspection. Elles ne créent pas de VM :

```bash
sudo ./proxforge.sh doctor
sudo ./proxforge.sh module list
sudo ./proxforge.sh module validate fedora
sudo ./proxforge.sh module validate debian
sudo ./proxforge.sh pve doctor
sudo ./proxforge.sh pve nodes
sudo ./proxforge.sh pve storages
sudo ./proxforge.sh pve bridges
```

Vérifier les résultats, la disponibilité d'un stockage et d'un bridge de test,
les quotas et les sauvegardes avant d'envisager `deploy`. La commande
`deploy` crée réellement une VM ; elle ne fait pas partie du pré-vol
non-destructif.

Utiliser un VMID, un nom et un stockage réservés aux tests, ne pas employer un
identifiant déjà utilisé et conserver une procédure de nettoyage contrôlée.
Ne pas tester rollback ou désinstallation de VM sur un invité ou un volume qui
n'appartient pas clairement à ProxForge.

## Rapport de test

Pour chaque essai sur hôte réel, consigner au minimum :

- version exacte de Proxmox VE et Debian ;
- hash/commit ProxForge testé ;
- version du module et de l'image demandée ;
- méthode de vérification de l'image ;
- stockage, bridge et VMID choisis ;
- résultat de chaque étape et état final observé dans Proxmox ;
- sauvegarde et procédure de retour arrière ;
- tout avertissement ou écart observé.
