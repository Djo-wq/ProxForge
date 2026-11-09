#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PREFIX=""
REMOVE_CONFIG=false
REMOVE_DATA=false

usage() {
  cat <<'USAGE'
ProxForge system uninstaller

Usage:
  sudo bash scripts/uninstall.sh [--remove-config] [--remove-data]
  bash scripts/uninstall.sh --prefix ABSOLUTE_STAGING_DIRECTORY [options]

Options:
  --remove-config  Archive /etc/proxforge, then remove its configuration
  --remove-data    Remove ProxForge state, image cache, temporary files and logs
  --prefix DIR     Operate below DIR (for package staging and tests)
  --help           Show this help

Configuration and runtime data are preserved by default. --remove-config
creates a root-only timestamped archive before deleting the configuration.
USAGE
}

fail() { printf '[ERROR] ProxForge uninstaller: %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

while (( $# > 0 )); do
  case "$1" in
    --prefix)
      (( $# >= 2 )) || fail "--prefix requires an absolute directory."
      PREFIX="$2"; shift 2 ;;
    --remove-config) REMOVE_CONFIG=true; shift ;;
    --remove-data) REMOVE_DATA=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown option: $1 (use --help)." ;;
  esac
done

if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && "$PREFIX" != "/" ]] || fail "--prefix must be an absolute path other than /."
  [[ "$PREFIX" != *"/../"* && "$PREFIX" != */.. ]] || fail "--prefix must not contain parent-directory traversal."
  reject_symlink_prefix_components "$PREFIX"
  [[ -d "$PREFIX" ]] || fail "staging prefix does not exist: $PREFIX"
  PREFIX=$(cd -- "$PREFIX" && pwd -P)
else
  [[ "$EUID" == "0" ]] || fail "run the system uninstallation as root (sudo)."
fi

prefix_path() {
  if [[ -n "$PREFIX" ]]; then printf '%s%s' "$PREFIX" "$1"; else printf '%s' "$1"; fi
}

assert_no_symlink_components() {
  local target="$1" current="" part
  local -a parts
  IFS='/' read -r -a parts <<< "${target#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    [[ ! -L "$current" ]] || fail "refusing to follow symbolic link in managed path: $current"
  done
}

LIB_DIR=$(prefix_path /usr/local/lib/proxforge)
ETC_DIR=$(prefix_path /etc/proxforge)
CONFIG_FILE="$ETC_DIR/config.json"
VAR_DIR=$(prefix_path /var/lib/proxforge)
LOG_DIR=$(prefix_path /var/log/proxforge)
BACKUP_DIR=$(prefix_path /var/backups/proxforge)
BIN_DIR=$(prefix_path /usr/local/bin)
LOCK_DIR=$(prefix_path /run/lock)

for path in "$LIB_DIR" "$ETC_DIR" "$VAR_DIR" "$LOG_DIR" "$BIN_DIR" "$LOCK_DIR"; do
  assert_no_symlink_components "$path"
done
mkdir -p -- "$LOCK_DIR"
command -v flock >/dev/null 2>&1 || fail "flock is required to safely coordinate installation changes."
exec 9>"$LOCK_DIR/proxforge-install.lock"
flock -n 9 || fail "another ProxForge installation or removal is already running."

[[ -d "$LIB_DIR" && ! -L "$LIB_DIR" ]] || fail "managed installation directory does not exist: $LIB_DIR"
[[ -f "$LIB_DIR/.proxforge-install-manifest" && ! -L "$LIB_DIR/.proxforge-install-manifest" ]] ||
  fail "installation manifest is missing; refusing to remove an unmanaged directory."
[[ "$(cat -- "$LIB_DIR/.proxforge-install-manifest")" == "proxforge-managed-install-v1" ]] ||
  fail "installation manifest is invalid; refusing to remove an unmanaged directory."

if [[ "$REMOVE_CONFIG" == "true" && ( -e "$ETC_DIR" || -L "$ETC_DIR" ) ]]; then
  [[ -d "$ETC_DIR" && ! -L "$ETC_DIR" ]] || fail "configuration path is not a regular directory."
  command -v tar >/dev/null 2>&1 || fail "tar is required to back up configuration before removal."
  if find "$ETC_DIR" -type l -print -quit | grep -q .; then
    fail "configuration directory contains symbolic links; refusing backup/removal."
  fi
  assert_no_symlink_components "$BACKUP_DIR"
  mkdir -p -- "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/config-$(date -u +%Y%m%dT%H%M%SZ)-$$.tar.gz"
  tar -C "$(dirname -- "$ETC_DIR")" -czf "$backup_file" "$(basename -- "$ETC_DIR")"
  chmod 0600 "$backup_file"
  if [[ "$EUID" == "0" ]]; then chown root:root "$backup_file" "$BACKUP_DIR"; fi
  rm -rf -- "$ETC_DIR"
  info "Configuration archived at $backup_file and removed from the system."
elif [[ -d "$ETC_DIR" ]]; then
  info "Configuration preserved at $ETC_DIR."
fi

remove_managed_link() {
  local path="$1"
  if [[ -L "$path" ]]; then
    [[ "$(readlink -- "$path")" == "../lib/proxforge/proxforge.sh" ]] ||
      fail "refusing to remove unmanaged symbolic link: $path"
    rm -- "$path"
  elif [[ -e "$path" ]]; then
    info "Leaving unrelated non-symlink path untouched: $path"
  fi
}

remove_managed_link "$BIN_DIR/proxforge"
remove_managed_link "$BIN_DIR/proxforge.sh"
rm -rf -- "$LIB_DIR"
info "ProxForge application files removed from $LIB_DIR."

if [[ "$REMOVE_DATA" == "true" ]]; then
  for path in "$VAR_DIR" "$LOG_DIR"; do
    if [[ -e "$path" ]]; then
      [[ -d "$path" && ! -L "$path" ]] || fail "refusing to remove non-directory data path: $path"
      rm -rf -- "$path"
    fi
  done
  info "ProxForge state, image cache, temporary files and logs removed."
else
  info "Runtime data preserved under $VAR_DIR and $LOG_DIR. Use --remove-data to delete it."
fi

if [[ "$REMOVE_CONFIG" == "false" ]]; then
  info "Configuration remains available for a future reinstall."
fi
