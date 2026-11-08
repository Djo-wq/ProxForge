#!/usr/bin/env bash
# ProxForge — Pi-hole (Debian 12) pour Proxmox VE 9.2
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in pct pveam pvesh; do command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }; done

CTID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-pihole-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-512}"
DISK_SIZE="${DISK_SIZE:-2G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

CT_CREATED=0
cleanup() { local exit_code=$?; (( exit_code != 0 )) && (( CT_CREATED )) && { pct stop "$CTID" >/dev/null 2>&1 || true; pct destroy "$CTID" >/dev/null 2>&1 || true; }; }
trap cleanup EXIT ERR

pveam update >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m pveam update échoué" >&2; exit 1; }
TEMPLATE_NAME=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}')
[[ -z "$TEMPLATE_NAME" ]] && { echo -e "\e[31m[ERREUR]\e[0m Template Debian 12 introuvable" >&2; exit 1; }
TEMPLATE_FILE="${TEMPLATE_NAME##*/}"
[[ -f "/var/lib/vz/template/cache/${TEMPLATE_FILE}" ]] || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Téléchargement échoué" >&2; exit 1; }

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" --hostname "$HN" --arch amd64 --ostype debian --cores "$CPU_CORES" --memory "$RAM_SIZE" --swap 0 --net0 name=eth0,bridge="$BRIDGE",ip=dhcp --rootfs "${STORAGE}:${DISK_SIZE}" --unprivileged 1 --description "Pi-hole - ProxForge" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Création échouée" >&2; exit 1; }
CT_CREATED=1

if [[ "$START_LXC" == "yes" ]]; then
  pct start "$CTID" >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Démarrage échoué" >&2; exit 1; }
  pct exec "$CTID" -- bash -c 'until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 1; done' || { echo -e "\e[31m[ERREUR]\e[0m Timeout DHCP" >&2; exit 1; }
  pct exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive && apt-get update -y && apt-get upgrade -y && apt-get install -y curl wget sudo iproute2 ca-certificates && IP_CIDR=$(ip -f inet addr show eth0 | awk \"/inet / {print \\$2}\") && mkdir -p /etc/pihole && cat <<EOF > /etc/pihole/setupVars.conf
PIHOLE_INTERFACE=eth0
IPv4_address=${IP_CIDR}
IPv6_address=
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
DNSMASQ_LISTENING=single
EOF
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended && pihole -a -p \"Proxmox2026!\"' >/dev/null || { echo -e "\e[31m[ERREUR]\e[0m Installation échouée" >&2; exit 1; }
fi

LXC_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' || echo "")
echo -e "\n\e[32m[SUCCÈS]\e[0m LXC Pi-hole déployé (ID: $CTID) !"
[[ -n "$LXC_IP" ]] && echo -e "\e[36m[INFO]\e[0m Interface : http://${LXC_IP}/admin\n\e[36m[INFO]\e[0m Mot de passe : Proxmox2026!\n\e[31m[⚠️]\\e[0m Fixez l'IP ${LXC_IP} en statique !" || echo -e "\e[33m[AVERTISSEMENT]\e[0m Cherchez l'IP dans Proxmox."
echo -e ""
