#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PREFIX=""
PROVISION_FEDORA_KEYRING=false
INSTALL_DEPENDENCIES=false
STAGE=""
PREVIOUS=""
LIB_SWAPPED=false
CONFIG_CREATED=false

usage() {
  cat <<'USAGE'
ProxForge system installer

Usage:
  sudo bash scripts/install.sh [--provision-fedora-keyring]
  bash scripts/install.sh --prefix ABSOLUTE_STAGING_DIRECTORY

Options:
  --provision-fedora-keyring  Download and verify the pinned Fedora keyring
  --install-dependencies     Install missing Debian packages using apt-get
  --prefix DIR                Install below DIR (for package staging and tests)
  --help                      Show this help

A prefixed installation is a staging operation: host Proxmox checks and root
privileges are intentionally skipped. It does not alter the live system paths.
USAGE
}

fail() { printf '[ERROR] ProxForge installer: %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

reject_symlink_prefix_components() {
  local target="$1" current="" part
  local -a parts
  IFS='/' read -r -a parts <<< "${target#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    [[ ! -L "$current" ]] || fail "refusing to use a staging prefix that traverses a symbolic link: $current"
  done
}

while (( $# > 0 )); do
  case "$1" in
    --provision-fedora-keyring) PROVISION_FEDORA_KEYRING=true; shift ;;
    --install-dependencies) INSTALL_DEPENDENCIES=true; shift ;;
    --prefix)
      (( $# >= 2 )) || fail "--prefix requires an absolute directory."
      PREFIX="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown option: $1 (use --help)." ;;
  esac
done

if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && "$PREFIX" != "/" ]] || fail "--prefix must be an absolute path other than /."
  [[ "$PREFIX" != *"/../"* && "$PREFIX" != */.. ]] || fail "--prefix must not contain parent-directory traversal."
  reject_symlink_prefix_components "$PREFIX"
  mkdir -p -- "$PREFIX"
  PREFIX=$(cd -- "$PREFIX" && pwd -P)
  reject_symlink_prefix_components "$PREFIX"
  STAGING_MODE=true
else
  STAGING_MODE=false
  [[ "$EUID" == "0" ]] || fail "run the system installation as root (sudo)."
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

for cmd in bash install cp mv ln mkdir chmod find mktemp readlink stat grep; do
  require_command "$cmd"
done

if [[ "$STAGING_MODE" == "true" ]]; then
  require_command jq
  require_command flock
else
  [[ "${BASH_VERSINFO[0]}" -gt 5 || ("${BASH_VERSINFO[0]}" -eq 5 && "${BASH_VERSINFO[1]}" -ge 1) ]] ||
    fail "Bash 5.1 or newer is required."
  require_command pveversion
  [[ -d /etc/pve ]] || fail "/etc/pve is missing; this does not look like a Proxmox VE node."
  pve_version=$(pveversion 2>/dev/null | head -n 1 || true)
  [[ "$pve_version" =~ ^pve-manager/9\. ]] || fail "Proxmox VE 9.x is required; detected: ${pve_version:-unknown}."
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] ||
      fail "Proxmox VE 9.x on Debian 13 is required."
  else
    fail "/etc/os-release is unavailable; unable to verify the host OS."
  fi
  if [[ "$INSTALL_DEPENDENCIES" == "true" ]]; then
    require_command apt-get
    apt-get update
    apt-get install --yes --no-install-recommends jq curl util-linux qemu-utils coreutils gpgv gnupg iproute2
  fi
  for cmd in curl jq flock qemu-img sha256sum sha512sum gpgv qm pvesh pvesm ip; do
    require_command "$cmd"
  done
  if [[ "$PROVISION_FEDORA_KEYRING" == "true" ]]; then require_command gpg; fi
fi

for src in proxforge.sh src scripts docs; do
  [[ -e "$ROOT_DIR/$src" && ! -L "$ROOT_DIR/$src" ]] || fail "required source path is missing or unsafe: $src"
  if find "$ROOT_DIR/$src" -type l -print -quit | grep -q .; then
    fail "source path contains a symbolic link: $src"
  fi
done
[[ -f "$ROOT_DIR/src/config/defaults.json" && -f "$ROOT_DIR/proxforge.sh" && -f "$ROOT_DIR/src/proxforge.sh" ]] || fail "source tree is incomplete."

LIB_DIR=$(prefix_path /usr/local/lib/proxforge)
LIB_PARENT=$(dirname -- "$LIB_DIR")
ETC_DIR=$(prefix_path /etc/proxforge)
CONFIG_FILE="$ETC_DIR/config.json"
VAR_DIR=$(prefix_path /var/lib/proxforge)
LOG_DIR=$(prefix_path /var/log/proxforge)
BACKUP_DIR=$(prefix_path /var/backups/proxforge)
BIN_DIR=$(prefix_path /usr/local/bin)
LOCK_DIR=$(prefix_path /run/lock)

for path in "$LIB_PARENT" "$LIB_DIR" "$ETC_DIR" "$CONFIG_FILE" "$(dirname -- "$VAR_DIR")" "$VAR_DIR" "$(dirname -- "$LOG_DIR")" "$LOG_DIR" "$BIN_DIR" "$LOCK_DIR"; do
  assert_no_symlink_components "$path"
done
mkdir -p -- "$LIB_PARENT" "$ETC_DIR" "$(dirname -- "$VAR_DIR")" "$(dirname -- "$LOG_DIR")" "$BIN_DIR" "$LOCK_DIR"
chmod 0755 "$LIB_PARENT" "$BIN_DIR"
chmod 0750 "$ETC_DIR"
exec 9>"$LOCK_DIR/proxforge-install.lock"
flock -n 9 || fail "another ProxForge installation or removal is already running."

# Do not replace an unrelated directory or executable that happens to use our name.
if [[ -e "$LIB_DIR" || -L "$LIB_DIR" ]]; then
  [[ -d "$LIB_DIR" && ! -L "$LIB_DIR" && -f "$LIB_DIR/.proxforge-install-manifest" && ! -L "$LIB_DIR/.proxforge-install-manifest" ]] ||
    fail "existing $LIB_DIR is not a ProxForge-managed installation; refusing to overwrite it."
  [[ "$(cat -- "$LIB_DIR/.proxforge-install-manifest")" == "proxforge-managed-install-v1" ]] ||
    fail "existing installation manifest is invalid; refusing to overwrite it."
fi

for link in "$BIN_DIR/proxforge" "$BIN_DIR/proxforge.sh"; do
  if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" ]] || fail "refusing to replace non-symlink executable: $link"
    case "$(readlink -- "$link")" in
      ../lib/proxforge/proxforge.sh) ;;
      *) fail "refusing to replace unmanaged symlink: $link" ;;
    esac
  fi
done

STAGE=$(mktemp -d "$LIB_PARENT/.proxforge-stage.XXXXXX")
cleanup() { [[ -z "$STAGE" || ! -d "$STAGE" ]] || rm -rf -- "$STAGE"; }
rollback() {
  local rc=$?
  trap - EXIT
  if [[ "$LIB_SWAPPED" == "true" ]]; then
    [[ ! -d "$LIB_DIR" ]] || rm -rf -- "$LIB_DIR"
    if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
      mv -T -- "$PREVIOUS" "$LIB_DIR" || true
    else
      for link in "$BIN_DIR/proxforge" "$BIN_DIR/proxforge.sh"; do
        [[ ! -L "$link" || "$(readlink -- "$link")" != "../lib/proxforge/proxforge.sh" ]] || rm -f -- "$link"
      done
    fi
  fi
  if [[ "$CONFIG_CREATED" == "true" ]]; then rm -f -- "$CONFIG_FILE"; fi
  cleanup
  exit "$rc"
}
trap rollback EXIT

for item in proxforge.sh src scripts docs; do
  cp -a -- "$ROOT_DIR/$item" "$STAGE/"
done

# Preserve locally provisioned Fedora trust material across upgrades.
# The second source path supports upgrades from releases where trust/ lived at
# the installation root; new installations keep it under src/trust/.
for keyring_source in "$LIB_DIR/src/trust/keyrings" "$LIB_DIR/trust/keyrings"; do
  if [[ -e "$keyring_source" || -L "$keyring_source" ]]; then
    [[ -d "$keyring_source" && ! -L "$keyring_source" ]] ||
      fail "existing Fedora keyring path is not a managed directory: $keyring_source"
    if find "$keyring_source" -type l -print -quit | grep -q .; then
      fail "existing Fedora keyring directory contains symbolic links."
    fi
    mkdir -p -- "$STAGE/src/trust/keyrings"
    cp -an -- "$keyring_source/." "$STAGE/src/trust/keyrings/"
  fi
done

printf '%s\n' 'proxforge-managed-install-v1' > "$STAGE/.proxforge-install-manifest"
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/proxforge.sh" "$STAGE/src/proxforge.sh"
find "$STAGE/scripts" -type f -name '*.sh' -exec chmod 0750 {} +
[[ -d "$STAGE/src/trust/keyrings" ]] && chmod 0750 "$STAGE/src/trust/keyrings"

mkdir -p -- "$VAR_DIR/cache" "$VAR_DIR/tmp" "$VAR_DIR/state" "$LOG_DIR"
chmod 0750 "$VAR_DIR" "$VAR_DIR/cache" "$LOG_DIR"
chmod 0700 "$VAR_DIR/tmp" "$VAR_DIR/state"

if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || fail "existing configuration is not a regular file: $CONFIG_FILE"
else
  install -m 0640 -- "$ROOT_DIR/src/config/defaults.json" "$CONFIG_FILE"
  CONFIG_CREATED=true
fi
chmod 0640 "$CONFIG_FILE"

# Validate the effective configuration against the just-staged CLI before switching installs.
"$STAGE/proxforge.sh" --config "$CONFIG_FILE" config validate >/dev/null

PREVIOUS=""
if [[ -d "$LIB_DIR" ]]; then
  PREVIOUS="$LIB_DIR.previous.$$"
  [[ ! -e "$PREVIOUS" && ! -L "$PREVIOUS" ]] || fail "temporary rollback path already exists: $PREVIOUS"
  mv -T -- "$LIB_DIR" "$PREVIOUS"
fi
LIB_SWAPPED=true
mv -T -- "$STAGE" "$LIB_DIR"
STAGE=""
LIB_SWAPPED=true

# Links are relative so the same layout works in package staging roots.
ln -sfn -- ../lib/proxforge/proxforge.sh "$BIN_DIR/.proxforge-link.$$"
mv -Tf -- "$BIN_DIR/.proxforge-link.$$" "$BIN_DIR/proxforge"
ln -sfn -- ../lib/proxforge/proxforge.sh "$BIN_DIR/.proxforge-sh-link.$$"
mv -Tf -- "$BIN_DIR/.proxforge-sh-link.$$" "$BIN_DIR/proxforge.sh"

if [[ "$EUID" == "0" ]]; then
  chown -R root:root "$LIB_DIR" "$ETC_DIR"
  chown root:root "$VAR_DIR" "$VAR_DIR/cache" "$VAR_DIR/tmp" "$VAR_DIR/state" "$LOG_DIR"
fi
chmod 0750 "$ETC_DIR"
chmod 0640 "$CONFIG_FILE"

if [[ "$PROVISION_FEDORA_KEYRING" == "true" ]]; then
  [[ "$STAGING_MODE" == "false" ]] || fail "Fedora key provisioning is not available in staging mode."
  "$LIB_DIR/scripts/provision-fedora-keyring.sh"
fi

if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then rm -rf -- "$PREVIOUS"; fi
LIB_SWAPPED=false
CONFIG_CREATED=false
trap - EXIT
info "ProxForge installed at $LIB_DIR."
info "CLI: $BIN_DIR/proxforge"
info "Configuration: $CONFIG_FILE"
info "State: $VAR_DIR"
info "Logs: $LOG_DIR"
if [[ "$PROVISION_FEDORA_KEYRING" == "false" ]]; then
  info "Fedora keys were not downloaded. To provision them later, run: $LIB_DIR/scripts/provision-fedora-keyring.sh"
fi
if [[ "$STAGING_MODE" == "true" ]]; then
  info "Staging mode completed; no live host paths were modified."
fi
