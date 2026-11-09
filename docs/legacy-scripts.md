# Anciens scripts autonomes

Les dossiers `linux/`, `windows/`, `lxc/`, `network/` et
`Docker-vm/` à la racine sont une collection historique de scripts Bash
autonomes. Ils sont conservés à leurs emplacements d'origine pour préserver
les chemins existants.

Ils sont distincts de la CLI modulaire `proxforge.sh` et de ses modules dans
`distributions/`. Ils ne passent pas automatiquement par l'Image Manager,
le VM Lifecycle Manager ou l'Operations Manager, et ne sont pas couverts par
les mêmes garanties de tests. Ne pas supposer qu'un mécanisme de rollback ou
de vérification décrit pour la CLI s'applique à ces scripts.

Pour un nouveau déploiement, utiliser la CLI modulaire et suivre la procédure
de [pré-vol et de test](testing.md). Les anciens scripts doivent faire
l'objet d'une revue individuelle et d'un test isolé avant toute exécution sur
un nœud Proxmox.
