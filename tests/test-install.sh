#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

PREFIX="$TMP_ROOT/stage"

bash "$ROOT_DIR/scripts/install.sh" --prefix "$PREFIX" >/dev/null || fail "Initial staged installation failed"
LIB="$PREFIX/usr/local/lib/proxforge"
CONFIG="$PREFIX/etc/proxforge/config.json"

[[ -f "$LIB/.proxforge-install-manifest" ]] || fail "Install manifest is missing"
[[ -x "$LIB/proxforge.sh" ]] || fail "Installed CLI is not executable"
[[ -L "$PREFIX/usr/local/bin/proxforge" ]] || fail "CLI entry-point symlink is missing"
[[ "$(readlink "$PREFIX/usr/local/bin/proxforge")" == "../lib/proxforge/proxforge.sh" ]] ||
  fail "CLI entry-point symlink is not relocatable"
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || fail "Initial configuration was not created safely"
[[ "$(stat -c '%a' "$CONFIG")" == "640" ]] || fail "Configuration mode is not 0640"
[[ "$(stat -c '%a' "$PREFIX/var/lib/proxforge/tmp")" == "700" ]] || fail "Temporary directory mode is not 0700"
[[ "$(stat -c '%a' "$PREFIX/var/lib/proxforge/state")" == "700" ]] || fail "State directory mode is not 0700"
"$LIB/proxforge.sh" --version >/dev/null || fail "Installed CLI could not start"
pass "Staged install creates secure FHS paths, configuration and relocatable CLI links"

jq '.log_level="DEBUG"' "$CONFIG" > "$TMP_ROOT/config.json"
cat "$TMP_ROOT/config.json" > "$CONFIG"
bash "$ROOT_DIR/scripts/install.sh" --prefix "$PREFIX" >/dev/null || fail "Idempotent staged upgrade failed"
jq -e '.log_level=="DEBUG"' "$CONFIG" >/dev/null || fail "Upgrade overwrote the administrator configuration"
[[ -f "$LIB/.proxforge-install-manifest" ]] || fail "Upgrade lost its install manifest"
pass "Repeated installation is idempotent and preserves administrator configuration"

bash "$ROOT_DIR/scripts/uninstall.sh" --prefix "$PREFIX" >/dev/null || fail "Default staged uninstall failed"
[[ ! -e "$LIB" ]] || fail "Application directory remains after uninstall"
[[ ! -L "$PREFIX/usr/local/bin/proxforge" ]] || fail "Managed CLI symlink remains after uninstall"
[[ -f "$CONFIG" ]] || fail "Default uninstall removed configuration unexpectedly"
[[ -d "$PREFIX/var/lib/proxforge" && -d "$PREFIX/var/log/proxforge" ]] ||
  fail "Default uninstall removed runtime data unexpectedly"
pass "Default uninstall removes application files and preserves configuration and data"

bash "$ROOT_DIR/scripts/install.sh" --prefix "$PREFIX" >/dev/null || fail "Reinstall after default uninstall failed"
bash "$ROOT_DIR/scripts/uninstall.sh" --prefix "$PREFIX" --remove-config --remove-data >/dev/null ||
  fail "Full staged uninstall failed"
[[ ! -e "$CONFIG" && ! -d "$PREFIX/var/lib/proxforge" && ! -d "$PREFIX/var/log/proxforge" ]] ||
  fail "Explicit config/data removal left managed paths behind"
BACKUP=$(find "$PREFIX/var/backups/proxforge" -maxdepth 1 -type f -name 'config-*.tar.gz' -print -quit)
[[ -n "$BACKUP" && -f "$BACKUP" ]] || fail "Configuration backup archive was not created"
[[ "$(stat -c '%a' "$BACKUP")" == "600" ]] || fail "Configuration backup permissions are not 0600"
tar -tzf "$BACKUP" | grep -q 'proxforge/config.json' || fail "Backup archive does not contain config.json"
pass "Explicit config removal first archives configuration with restrictive permissions"

BAD_PREFIX="$TMP_ROOT/bad-stage"
mkdir -p "$BAD_PREFIX/etc/proxforge"
printf '{"unknown_setting":true}\n' > "$BAD_PREFIX/etc/proxforge/config.json"
if bash "$ROOT_DIR/scripts/install.sh" --prefix "$BAD_PREFIX" >/dev/null 2>&1; then
  fail "Installer accepted an invalid configuration"
fi
[[ ! -e "$BAD_PREFIX/usr/local/lib/proxforge" ]] || fail "Failed install left a partial application tree"
jq -e '.unknown_setting==true' "$BAD_PREFIX/etc/proxforge/config.json" >/dev/null ||
  fail "Failed install modified the administrator's invalid configuration"
pass "Invalid configuration blocks installation without being overwritten or leaving partial files"

if bash "$ROOT_DIR/scripts/install.sh" --prefix "$TMP_ROOT/../escape" >/dev/null 2>&1; then
  fail "Installer accepted parent-directory traversal in --prefix"
fi
if bash "$ROOT_DIR/scripts/uninstall.sh" --prefix / >/dev/null 2>&1; then
  fail "Uninstaller accepted / as a staging prefix"
fi
mkdir -p "$TMP_ROOT/real-prefix"
ln -s "$TMP_ROOT/real-prefix" "$TMP_ROOT/prefix-link"
if bash "$ROOT_DIR/scripts/install.sh" --prefix "$TMP_ROOT/prefix-link/install" >/dev/null 2>&1; then
  fail "Installer accepted a staging path traversing a symlink"
fi
pass "Installer and uninstaller reject unsafe staging paths and symlinked prefixes"

pass "Installation tests completed without touching live /etc, /var, /usr/local or Proxmox resources"
