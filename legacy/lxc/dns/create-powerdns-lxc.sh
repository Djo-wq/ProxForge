#!/usr/bin/env bash
# ProxForge — PowerDNS & Poweradmin (Debian 12) pour Proxmox VE 9.2
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo -e "\e[31m[ERREUR]\e[0m Root requis." >&2; exit 1; }
for cmd in pct pveam pvesh; do command -v "$cmd" >/dev/null 2>&1 || { echo -e "\e[31m[ERREUR]\e[0m $cmd introuvable." >&2; exit 1; }; done

CTID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo "1000")
CTID="${CTID:-$CTID_DEFAULT}"
HN="${HN:-powerdns-lxc-$CTID}"
CPU_CORES="${CPU_CORES:-1}"
RAM_SIZE="${RAM_SIZE:-1024}"
DISK_SIZE="${DISK_SIZE:-4G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
START_LXC="${START_LXC:-yes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

CT_CREATED=0
cleanup() { local exit_code=$?; (( exit_code != 0 )) && (( CT_CREATED )) && { pct stop "$CTID" >/dev/null 2>&1 || true; pct destroy "$CTID" >/dev/null 2>&1 || true; }; }
trap cleanup EXIT ERR

pveam update >/dev/null || { echo -e "\e
