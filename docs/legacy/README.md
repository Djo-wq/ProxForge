# Scripts historiques

Ce répertoire contient les anciens scripts Bash autonomes du dépôt. Ils sont conservés pour référence et pour les utilisateurs qui les consultent encore, mais ils ne font pas partie du runtime modulaire actuel.

## Classement

- `vm/linux/` : création de VM Linux (Arch, Kali, Debian, Fedora et Ubuntu).
- `vm/windows/` : création de VM Windows.
- `lxc/containers/` : conteneur Docker générique.
- `lxc/dns/` : AdGuard, Pi-hole, PowerDNS et Technitium.
- `lxc/databases/` : MariaDB, MongoDB et PostgreSQL.
- `lxc/media/` : Immich et Jellyfin.
- `lxc/remote-access/` : Cloudflared, Tailscale, NetBird et WireGuard.
- `network/` : OPNsense.
- `docker-vm/` : ancienne VM Docker.

## Statut et précautions

Ces scripts ne passent pas automatiquement par les contrats des modules, l'Image Manager, le VM Lifecycle Manager ou l'Operations Manager de la CLI actuelle. Ils ne bénéficient pas des mêmes garanties de tests.

La CI vérifie leur syntaxe Bash, mais ne les exécute jamais. Ils peuvent télécharger des composants, créer ou modifier des ressources Proxmox et installer des services. Leur déplacement dans `legacy/` ne les rend ni sûrs ni validés.

Pour les nouveaux déploiements, utiliser le moteur modulaire décrit dans le [README principal](../../README.md). Toute maintenance d'un script historique doit faire l'objet d'une revue individuelle et d'un essai isolé sur un environnement de test.
