# Suite de tests

Lancer l'ensemble des tests depuis la racine :

```bash
make test
```

Le runner commence par vérifier la syntaxe des scripts Bash, puis exécute les
tests des contrats JSON, du chargeur de modules, de la CLI, de l'installation,
des modules Fedora et Debian, du Core, de l'Image Manager, du Proxmox Adapter,
du VM Lifecycle Manager et de l'Operations Manager.

Les tests de composants utilisent des fixtures, des commandes simulées et des
répertoires temporaires. Ils ne sont pas conçus pour créer ou supprimer des
ressources sur un vrai cluster.

Voir [la stratégie de test et le pré-vol](../docs/development/testing.md) pour connaître
les limites et l'ordre recommandé avant une première validation sur Proxmox.
