# Tests et préparation à une première validation

## Contrôles automatisés

Depuis la racine du dépôt :

```bash
make syntax
make test
make lint
make check
```

- `make syntax` vérifie le parsing de tous les scripts Bash maintenus et historiques, sans les exécuter.
- `make test` lance la suite hermétique.
- `make lint` lance ShellCheck sur les points d'entrée maintenus et les scripts de maintenance.
- `make check` exécute ShellCheck et toute la suite de tests.

Dépendances principales : Bash 5.1 ou supérieur, `jq` et ShellCheck pour le lint.

## Ce que les tests ne font pas

La suite automatisée est hermétique. Elle utilise des commandes simulées et des fichiers temporaires. Elle ne crée ni ne supprime de VM réelle, ne libère pas de volume réel et ne valide pas un stockage ou un bridge physique.

Les scripts de `legacy/` sont vérifiés en syntaxe uniquement. Ils ne sont pas exécutés par la suite de tests.

## Pré-vol recommandé

Sur une machine de développement, cloner le dépôt et lancer `make check`. Pour vérifier l'installation sans modifier les répertoires système, utiliser un préfixe temporaire :

```bash
STAGE_DIR=$(mktemp -d)
bash scripts/install.sh --prefix "$STAGE_DIR"
bash scripts/uninstall.sh --prefix "$STAGE_DIR"
rm -rf -- "$STAGE_DIR"
```

Sur un nœud de test Proxmox VE 9.2+ / Debian 13 dédié, commencer par les commandes d'inspection :

```bash
./proxforge.sh doctor
./proxforge.sh module list
./proxforge.sh module validate fedora
./proxforge.sh module validate debian
./proxforge.sh pve doctor
./proxforge.sh pve nodes
./proxforge.sh pve storages
./proxforge.sh pve bridges
```

Exécuter ces commandes en root (ou les préfixer par `sudo` depuis un compte
administrateur). Le moteur et l'installateur exigent Proxmox VE 9.2 ou plus récent
sur Debian 13.

Avant les déploiements de test :
- **Fedora :** provisionner le trousseau officiel épinglé avec
  `bash scripts/install.sh --provision-fedora-keyring` lors de l'installation,
  ou `/usr/local/lib/proxforge/scripts/provision-fedora-keyring.sh` après
  installation. Sans trousseau valide, le module Fedora échoue volontairement
  à la vérification de signature.
- **Debian :** `allow_official_tls_checksum` reste à `false` par défaut.
  Le garder désactivé dans `/etc/proxforge/config.json`. Pour un essai ponctuel,
  créer un override séparé afin de ne pas modifier la configuration persistante :

  ```bash
  cat > /root/proxforge-debian-test.json <<'JSON'
  {"allow_official_tls_checksum":true}
  JSON
  chmod 0600 /root/proxforge-debian-test.json
  proxforge --config /root/proxforge-debian-test.json config validate
  proxforge --config /root/proxforge-debian-test.json module image debian latest
  ```

  Si le pré-vol est validé et que le déploiement est autorisé, fournir aussi
  `--config /root/proxforge-debian-test.json` avant `deploy`. Le checksum Debian
  est vérifié via TLS et non via une signature OpenPGP détachée. Supprimer le
  fichier d'override à la fin des essais.

Vérifier les résultats, la disponibilité d'un stockage et d'un bridge de test, les quotas et les sauvegardes avant d'envisager `deploy`. Cette commande crée réellement une VM et ne fait pas partie du pré-vol non-destructif.

Utiliser un VMID, un nom et un stockage réservés aux tests. Ne pas utiliser un identifiant déjà occupé et conserver une procédure de nettoyage contrôlée. Ne pas tester rollback ou désinstallation sur un invité ou un volume qui n'appartient pas clairement à ProxForge.

## Rapport de test

Pour chaque essai sur hôte réel, consigner au minimum : la version de Proxmox VE et Debian, le commit ProxForge, le module et l'image demandés, la méthode de vérification, le stockage, le bridge, le VMID, les résultats observés et la procédure de retour arrière.
