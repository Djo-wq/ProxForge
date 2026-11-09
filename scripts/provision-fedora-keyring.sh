#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
REGISTRY="$ROOT_DIR/trust/keyrings.json"
TARGET_DIR="$ROOT_DIR/trust/keyrings"
TARGET_FILE="$TARGET_DIR/fedora-release.gpg"
SOURCE_URL="https://fedoraproject.org/fedora.gpg"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxforge-fedora-keyring.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf '[ERROR] Fedora keyring provisioning: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" == "0" ]] || fail "run this provisioning step as root."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v gpg >/dev/null 2>&1 || fail "gpg is required."
command -v jq >/dev/null 2>&1 || fail "jq is required."
[[ -f "$REGISTRY" && ! -L "$REGISTRY" ]] || fail "trusted fingerprint registry is missing or unsafe."

jq -e '
  type == "object" and .schema_version == 1 and
  (.keyrings["fedora-release"].fingerprints | type == "array" and length == 2)
' "$REGISTRY" >/dev/null || fail "Fedora release fingerprint registry is invalid."

curl --silent --show-error --fail \
  --proto '=https' --tlsv1.2 --location --max-redirs 3 \
  --connect-timeout 30 --max-time 120 \
  --output "$TMP_DIR/fedora.gpg" "$SOURCE_URL" ||
  fail "could not download Fedora's official public key bundle."

[[ -s "$TMP_DIR/fedora.gpg" && ! -L "$TMP_DIR/fedora.gpg" ]] ||
  fail "downloaded public key bundle is empty or unsafe."

mapfile -t downloaded_fingerprints < <(
  gpg --batch --show-keys --with-colons --fingerprint "$TMP_DIR/fedora.gpg" |
    awk -F: '$1 == "fpr" { print toupper($10) }' |
    sort -u
)
(( ${#downloaded_fingerprints[@]} > 0 )) ||
  fail "could not read OpenPGP fingerprints from Fedora's key bundle."

while IFS= read -r expected; do
  [[ -n "$expected" ]] || continue
  found=false
  for actual in "${downloaded_fingerprints[@]}"; do
    if [[ "$actual" == "$expected" ]]; then
      found=true
      break
    fi
  done
  [[ "$found" == "true" ]] ||
    fail "the downloaded key bundle does not contain pinned fingerprint $expected."
done < <(jq -r '.keyrings["fedora-release"].fingerprints[] | ascii_upcase' "$REGISTRY")

install -d -o root -g root -m 0750 "$TARGET_DIR"
install -o root -g root -m 0640 "$TMP_DIR/fedora.gpg" "$TARGET_FILE"

printf '[INFO] Installed Fedora public keyring: %s\n' "$TARGET_FILE"
printf '[INFO] Both Fedora 44 and Fedora 45 fingerprints matched the repository trust registry.\n'
printf '[INFO] Unpinned keys in the bundle remain untrusted by ProxForge.\n'
