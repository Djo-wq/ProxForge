# Scripts d'administration

Ce dossier contient les utilitaires d'installation système de la CLI modulaire :

- `install.sh` : vérifie les prérequis et installe ProxForge sous les chemins
  système documentés ; `--prefix` permet un staging isolé.
- `uninstall.sh` : retire les fichiers gérés ; la configuration et les
  données sont conservées par défaut.
- `provision-fedora-keyring.sh` : télécharge le trousseau public Fedora et
  compare ses empreintes au registre versionné. Cette opération doit être
  demandée explicitement.

Consulter [la procédure d'installation](../docs/phases/phase-10-installation.md)
avant une installation sur un hôte réel.
