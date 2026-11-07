ProxForge



Proxmox VE — Scripts d'Automatisation de VM

Ce dépôt contient une collection de scripts Bash autonomes (standalone) conçus pour déployer rapidement des machines virtuelles (VM) sur Proxmox VE 8.x / 7.x sans aucune dépendance externe.

Tous les scripts téléchargent les images officielles, configurent le stockage UEFI/OVMF, importent les disques virtuels, préparent le système Cloud-Init ou l'automatisation d'installation, puis démarrent la VM en une seule ligne de commande.

⚠️ Remarques de Sécurité
Windows Server : Le mot de passe du compte Administrator créé automatiquement par create-windows-vm.sh est Proxmox2026!. Veillez à le modifier immédiatement après votre première connexion.

Droits d'exécution : Ces scripts modifient les ressources hyperviseur via l'API CLI Proxmox (qm, pvesm, pvesh) et nécessitent d'être exécutés par l'utilisateur root.

📜 Licence
Ce projet est distribué sous licence MIT. Vous êtes libre de l'utiliser, le modifier et le redistribuer.
