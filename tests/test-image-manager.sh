#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
export FAKE_CURL_LOG="$TMP_ROOT/curl.log"
export FAKE_QEMU_LOG="$TMP_ROOT/qemu.log"
export FAKE_CHECKSUM_FILE="$TMP_ROOT/SHA256SUMS"
export FAKE_IMAGE_FILE="$TMP_ROOT/valid-image"
export FAKE_BAD_IMAGE_FILE="$TMP_ROOT/bad-image"
export FAKE_DEBIAN_CHECKSUM_FILE="$TMP_ROOT/DEBIAN-SHA512SUMS"
export FAKE_DEBIAN_IMAGE_FILE="$TMP_ROOT/debian-image"
: > "$FAKE_CURL_LOG"
: > "$FAKE_QEMU_LOG"
printf 'synthetic qcow2 fixture payload\n' > "$FAKE_IMAGE_FILE"
printf 'different synthetic payload\n' > "$FAKE_BAD_IMAGE_FILE"
printf 'synthetic Debian qcow2 fixture\n' > "$FAKE_DEBIAN_IMAGE_FILE"
debian_digest=$(sha512sum "$FAKE_DEBIAN_IMAGE_FILE" | awk '{print $1}')
printf '%s  debian-13-generic-amd64.qcow2\n' "$debian_digest" > "$FAKE_DEBIAN_CHECKSUM_FILE"
digest=$(sha256sum "$FAKE_IMAGE_FILE" | awk '{print $1}')
printf '%s  fedora-cloud.qcow2\n' "$digest" > "$FAKE_CHECKSUM_FILE"

cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
url="" output="" headers=""
while (($#)); do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
if [[ "${FAKE_REDIRECT:-0}" == "1" && "$url" == "https://images.example.test/SHA256SUMS" ]]; then
  printf 'HTTP/1.1 302 Found\r\nLocation: https://unapproved.example.test/SHA256SUMS\r\n\r\n' > "$headers"
  : > "$output"
  printf '302'
  exit 0
fi
if [[ "${FAKE_HTTP_STATUS:-200}" != "200" ]]; then
  printf 'HTTP/1.1 %s Fake\r\n\r\n' "$FAKE_HTTP_STATUS" > "$headers"
  : > "$output"
  printf '%s' "$FAKE_HTTP_STATUS"
  exit 0
fi
printf 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n' > "$headers"
case "$url" in
  https://images.example.test/SHA256SUMS)
    cp -- "${FAKE_CHECKSUM_SOURCE:-$FAKE_CHECKSUM_FILE}" "$output"
    ;;
  https://images.example.test/fedora-cloud.qcow2)
    if [[ "${FAKE_BAD_IMAGE:-0}" == "1" ]]; then
      cp -- "$FAKE_BAD_IMAGE_FILE" "$output"
    else
      cp -- "$FAKE_IMAGE_FILE" "$output"
    fi
    ;;
  https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
    cp -- "$FAKE_DEBIAN_CHECKSUM_FILE" "$output"
    ;;
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2)
    cp -- "$FAKE_DEBIAN_IMAGE_FILE" "$output"
    ;;
  *)
    printf 'Unexpected URL: %s\n' "$url" >&2
    exit 9
    ;;
esac
printf '200'
MOCK
chmod 755 "$MOCK_BIN/curl"

cat > "$MOCK_BIN/qemu-img" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FAKE_QEMU_LOG"
if [[ "${FAKE_QEMU_FORMAT:-qcow2}" == "qcow2" ]]; then
  printf '{"format":"qcow2","virtual-size":1073741824}\n'
else
  printf '{"format":"raw","virtual-size":1073741824}\n'
fi
MOCK
chmod 755 "$MOCK_BIN/qemu-img"
export PATH="$MOCK_BIN:$PATH"

CACHE_DIR="$TMP_ROOT/cache"
CONFIG_FILE="$TMP_ROOT/config.json"
jq --arg cache "$CACHE_DIR" '.image_cache_dir=$cache | .image_max_bytes=10485760 | .allow_official_tls_checksum=false' \
  "$ROOT_DIR/src/config/defaults.json" > "$CONFIG_FILE"

export PF_CORE_ROOT="$ROOT_DIR/src"
export PF_CORE_CONFIG_FILE="$CONFIG_FILE"
export PF_CORE_TEST_MODE=1
export PF_IMAGE_TEST_MODE=1
source "$ROOT_DIR/src/core/bootstrap.sh"
pf_core_init || fail "Core initialization failed"

descriptor=$(jq -cn --arg url "https://images.example.test/fedora-cloud.qcow2" \
  --arg checksum "https://images.example.test/SHA256SUMS" \
  '{
    url:$url,
    filename:"fedora-cloud.qcow2",
    allowed_hosts:["images.example.test"],
    download_format:"file",
    archive_format:"none",
    disk_format:"qcow2",
    architecture:"x86_64",
    release:"40.2",
    checksum:{url:$checksum,algorithm:"sha256",filename:"SHA256SUMS"},
    signature:null,
    verification:{method:"official-tls-checksum",trust_level:"official_tls"},
    cloud_init:{status:"verified",datasource:"NoCloud"}
  }')

if pf_image_validate_descriptor "$descriptor" >/dev/null 2>&1; then
  fail "Official-TLS checksum accepted while policy was disabled"
fi
pass "official-TLS checksum is refused by default"

jq '.allow_official_tls_checksum=true' "$CONFIG_FILE" > "$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
pf_core_config_load "$CONFIG_FILE" || fail "Could not load explicit checksum policy"
pf_image_validate_descriptor "$descriptor" || fail "Valid descriptor rejected after explicit opt-in"
pass "official-TLS checksum requires explicit configuration opt-in"

# Exercise the Debian module's real SHA-512 acquisition contract end to end.
debian_descriptor=$(jq -cn '{
  url:"https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2",
  filename:"debian-13-generic-amd64.qcow2",
  allowed_hosts:["cloud.debian.org","cdimage.debian.org","cloudfront.debian.net"],
  download_format:"file",archive_format:"none",disk_format:"qcow2",
  architecture:"x86_64",release:"13",
  checksum:{
    url:"https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS",
    algorithm:"sha512",filename:"SHA512SUMS"
  },
  signature:null,
  verification:{method:"official-tls-checksum",trust_level:"official_tls"},
  cloud_init:{status:"verified",datasource:"NoCloud"}
}')
pf_image_validate_descriptor "$debian_descriptor" ||
  fail "Image Manager rejected the Debian official SHA-512 descriptor"
pf_image_acquire debian "$debian_descriptor" ||
  fail "Debian SHA-512 image acquisition failed"
jq -e '.distribution=="debian" and .release=="13" and
  .checksum_algorithm=="sha512" and .verification_method=="official-tls-checksum" and
  .trust_level=="official_tls" and .verification_result==true' \
  "$PF_IMAGE_PATH.json" >/dev/null || fail "Debian cache metadata lost its SHA-512 trust contract"
[[ "$PF_IMAGE_CACHE_HIT" == "false" ]] || fail "First Debian acquisition should be a cache miss"
DEBIAN_CACHE_PATH="$PF_IMAGE_PATH"
pf_image_acquire debian "$debian_descriptor" ||
  fail "Debian SHA-512 cache revalidation failed"
[[ "$PF_IMAGE_CACHE_HIT" == "true" && "$PF_IMAGE_PATH" == "$DEBIAN_CACHE_PATH" ]] ||
  fail "Debian cache hit did not reuse the verified SHA-512 image"
[[ "$(grep -Fc 'https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2' "$FAKE_CURL_LOG" || true)" == "1" ]] ||
  fail "Debian image was downloaded again on a cache hit"
pass "Debian SHA-512 download, digest verification, QCOW2 inspection and cache revalidation"

pf_image_acquire fedora "$descriptor" || fail "Verified test image could not be acquired"
[[ -f "$PF_IMAGE_PATH" ]] || fail "Image cache path was not returned"
[[ -f "$PF_IMAGE_PATH.json" ]] || fail "Image metadata sidecar was not published"
[[ "$PF_IMAGE_CACHE_HIT" == "false" ]] || fail "First acquisition should be a cache miss"
jq -e '.verification_result == true and .trust_level == "official_tls" and .checksum_algorithm == "sha256"' \
  "$PF_IMAGE_PATH.json" >/dev/null || fail "Cache metadata is incomplete"
IMAGE_PATH_FIRST="$PF_IMAGE_PATH"
pass "verified download, digest validation, disk-format validation and metadata publication"

pf_image_acquire fedora "$descriptor" || fail "Verified cache hit was rejected"
[[ "$PF_IMAGE_CACHE_HIT" == "true" ]] || fail "Second acquisition should be a cache hit"
[[ "$PF_IMAGE_PATH" == "$IMAGE_PATH_FIRST" ]] || fail "Cache path changed unexpectedly"
image_download_count=$(grep -Fc 'https://images.example.test/fedora-cloud.qcow2' "$FAKE_CURL_LOG" || true)
[[ "$image_download_count" == "1" ]] || fail "Image was downloaded again on cache hit"
pass "content-addressed cache hit avoids a second image download"

printf 'tampered bytes\n' > "$PF_IMAGE_PATH"
if pf_image_acquire fedora "$descriptor" >/dev/null 2>&1; then
  fail "Tampered cache image was accepted"
fi
[[ -f "$IMAGE_PATH_FIRST" ]] || fail "Invalid cache entry should be retained for operator inspection"
pass "tampered cache entry rejected without automatic overwrite"

descriptor_bad_host=$(jq '.url="https://unapproved.example.test/fedora-cloud.qcow2"' <<< "$descriptor")
if pf_image_validate_descriptor "$descriptor_bad_host" >/dev/null 2>&1; then
  fail "Descriptor with a host outside allowed_hosts was accepted"
fi
descriptor_userinfo=$(jq '.url="https://user@images.example.test/fedora-cloud.qcow2"' <<< "$descriptor")
if pf_image_validate_descriptor "$descriptor_userinfo" >/dev/null 2>&1; then
  fail "Descriptor with URL user-info was accepted"
fi
descriptor_traversal=$(jq '.release=".."' <<< "$descriptor")
if pf_image_acquire fedora "$descriptor_traversal" >/dev/null 2>&1; then
  fail "Path-traversal release identifier was accepted"
fi
pass "host allow-list, URL user-info and cache path traversal checks"

export FAKE_REDIRECT=1
ALLOWED_HOSTS='["images.example.test","cdn.example.test"]'
REDIRECT_OUTPUT="$TMP_ROOT/redirect-output"
curl_count_before=$(wc -l < "$FAKE_CURL_LOG")
if pf_image_download_url "https://images.example.test/SHA256SUMS" "$ALLOWED_HOSTS" "$REDIRECT_OUTPUT" 1024 >/dev/null 2>&1; then
  fail "Redirect to an unapproved host was followed"
fi
unset FAKE_REDIRECT
curl_count_after=$(wc -l < "$FAKE_CURL_LOG")
[[ "$curl_count_after" == "$((curl_count_before + 1))" ]] || fail "Image Manager contacted the unapproved redirect host"
pass "unapproved HTTPS redirect blocked before a second request"

descriptor_bad_digest=$(jq '.release="40.3"' <<< "$descriptor")
export FAKE_BAD_IMAGE=1
if pf_image_acquire fedora "$descriptor_bad_digest" >/dev/null 2>&1; then
  fail "Checksum mismatch was accepted"
fi
unset FAKE_BAD_IMAGE
bad_digest_files=$(find "$CACHE_DIR/fedora/40.3" -type f 2>/dev/null | wc -l)
[[ "$bad_digest_files" == "0" ]] || fail "Checksum-mismatched image was left in usable cache"
pass "checksum mismatch prevents image and metadata publication"

descriptor_bad_format=$(jq '.release="40.4"' <<< "$descriptor")
export FAKE_QEMU_FORMAT=raw
if pf_image_acquire fedora "$descriptor_bad_format" >/dev/null 2>&1; then
  fail "Image with a mismatched disk format was accepted"
fi
unset FAKE_QEMU_FORMAT
bad_format_files=$(find "$CACHE_DIR/fedora/40.4" -type f 2>/dev/null | wc -l)
[[ "$bad_format_files" == "0" ]] || fail "Format-mismatched image was left in usable cache"
pass "qemu-img format mismatch prevents cache publication"

SYMLINK_TARGET="$TMP_ROOT/cache-target"
SYMLINK_CACHE="$TMP_ROOT/cache-link"
mkdir -p "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_CACHE"
jq --arg cache "$SYMLINK_CACHE" '.image_cache_dir=$cache' "$CONFIG_FILE" > "$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
pf_core_config_load "$CONFIG_FILE" || fail "Could not load symlink-cache fixture"
if pf_image_init >/dev/null 2>&1; then
  fail "Symlinked cache root was accepted"
fi
pass "symlinked cache roots rejected before directory creation"

# Restore the trusted test cache before running the OpenPGP/cache integration cases.
jq --arg cache "$CACHE_DIR" '.image_cache_dir=$cache' "$CONFIG_FILE" > "$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
pf_core_config_load "$CONFIG_FILE" || fail "Could not restore the trusted image cache fixture"

if pf_image_verify_signature "$TMP_ROOT/nonexistent.sig" "$FAKE_CHECKSUM_FILE" vendor >/dev/null 2>&1; then
  fail "Unknown signing keyring was accepted"
fi
pass "OpenPGP verification fails closed without pinned trusted key material"

if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
  GNUPGHOME="$TMP_ROOT/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback --passphrase "" \
    --quick-generate-key "ProxForge Fixture Signing Key <fixture@example.invalid>" ed25519 sign 0 >/dev/null 2>&1
  signing_fingerprint=$(gpg --homedir "$GNUPGHOME" --batch --with-colons --fingerprint --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')
  [[ "$signing_fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]] || fail "Could not generate an OpenPGP test fingerprint"
  signed_payload="$TMP_ROOT/signed-checksum.txt"
  signature_file="$TMP_ROOT/signed-checksum.txt.sig"
  printf 'fixture publisher checksum\n' > "$signed_payload"
  gpg --homedir "$GNUPGHOME" --batch --yes --pinentry-mode loopback --passphrase "" \
    --local-user "$signing_fingerprint" --output "$signature_file" --detach-sign "$signed_payload" >/dev/null 2>&1
  export PF_IMAGE_TRUST_ROOT="$TMP_ROOT/test-trust"
  export PF_IMAGE_TRUST_FILE="$PF_IMAGE_TRUST_ROOT/keyrings.json"
  mkdir -m 0750 -p "$PF_IMAGE_TRUST_ROOT/keyrings"
  gpg --homedir "$GNUPGHOME" --batch --export "$signing_fingerprint" > "$PF_IMAGE_TRUST_ROOT/keyrings/vendor.gpg"
  jq -n --arg fingerprint "$signing_fingerprint" \
    '{schema_version:1,keyrings:{vendor:{fingerprints:[$fingerprint]}}}' > "$PF_IMAGE_TRUST_FILE"
  chmod 0640 "$PF_IMAGE_TRUST_FILE" "$PF_IMAGE_TRUST_ROOT/keyrings/vendor.gpg"
  chmod 0750 "$PF_IMAGE_TRUST_ROOT" "$PF_IMAGE_TRUST_ROOT/keyrings"
  pf_image_verify_signature "$signature_file" "$signed_payload" vendor || fail "Correct pinned OpenPGP signature was rejected"
  [[ "$PF_IMAGE_SIGNATURE_FINGERPRINT" == "$signing_fingerprint" ]] || fail "Verified signing fingerprint was not returned"
  pass "detached OpenPGP signature accepted for the exact pinned fingerprint"

  # Fedora publishes a clear-signed CHECKSUM document, not a separate .sig file.
  clear_signed_file="$TMP_ROOT/Fedora-CHECKSUM"
  verified_checksum_file="$TMP_ROOT/Fedora-CHECKSUM.verified"
  gpg --homedir "$GNUPGHOME" --batch --yes --pinentry-mode loopback --passphrase "" \
    --local-user "$signing_fingerprint" --output "$clear_signed_file" --clearsign "$FAKE_CHECKSUM_FILE" >/dev/null 2>&1
  pf_image_verify_clearsigned_checksum "$clear_signed_file" vendor "$verified_checksum_file" ||
    fail "Valid Fedora-style clearsigned CHECKSUM was rejected"
  cmp -s "$FAKE_CHECKSUM_FILE" "$verified_checksum_file" ||
    fail "gpgv did not return the authenticated plaintext CHECKSUM"
  pass "Fedora clearsigned CHECKSUM verifies and yields authenticated plaintext"

  descriptor_clearsigned=$(jq '
    .release="40.5" |
    .signature={url:.checksum.url,format:"openpgp-clearsigned-checksum",keyring_id:"vendor"} |
    .verification={method:"signed-checksum",trust_level:"signed"}
  ' <<< "$descriptor")
  export FAKE_CHECKSUM_SOURCE="$clear_signed_file"
  pf_image_validate_descriptor "$descriptor_clearsigned" ||
    fail "Image Manager rejected a valid Fedora clearsigned descriptor"
  pf_image_acquire fedora "$descriptor_clearsigned" ||
    fail "Fedora clearsigned image acquisition failed"
  jq -e '.verification_method=="signed-checksum" and .trust_level=="signed" and .verification_result==true' \
    "$PF_IMAGE_PATH.json" >/dev/null || fail "Fedora image cache metadata did not retain signed trust level"
  [[ "$PF_IMAGE_CACHE_HIT" == "false" ]] || fail "First clearsigned acquisition should be a cache miss"
  clearsigned_image_count=$(grep -Fc 'https://images.example.test/fedora-cloud.qcow2' "$FAKE_CURL_LOG" || true)
  pf_image_acquire fedora "$descriptor_clearsigned" ||
    fail "Fedora clearsigned cache hit failed signature re-verification"
  [[ "$PF_IMAGE_CACHE_HIT" == "true" ]] || fail "Second clearsigned acquisition should be a cache hit"
  [[ "$(grep -Fc 'https://images.example.test/fedora-cloud.qcow2' "$FAKE_CURL_LOG" || true)" == "$clearsigned_image_count" ]] ||
    fail "Clearsigned cache hit downloaded the image again"
  pass "Fedora clearsigned CHECKSUM gates both cache publication and every cache hit"

  tampered_digest=$(printf '%064d' 0)
  sed "s/$digest/$tampered_digest/" "$clear_signed_file" > "$TMP_ROOT/Fedora-CHECKSUM.tampered"
  [[ "$(<"$TMP_ROOT/Fedora-CHECKSUM.tampered")" != "$(<"$clear_signed_file")" ]] ||
    fail "Could not mutate the signed Fedora CHECKSUM payload"
  export FAKE_CHECKSUM_SOURCE="$TMP_ROOT/Fedora-CHECKSUM.tampered"
  descriptor_tampered=$(jq '.release="40.6"' <<< "$descriptor_clearsigned")
  if pf_image_acquire fedora "$descriptor_tampered" >/dev/null 2>&1; then
    fail "Tampered Fedora clearsigned CHECKSUM was accepted"
  fi
  tampered_checksum_cache=0
  if [[ -d "$CACHE_DIR/fedora/40.6" ]]; then
    tampered_checksum_cache=$(find "$CACHE_DIR/fedora/40.6" -type f | wc -l)
  fi
  [[ "$tampered_checksum_cache" == "0" ]] || fail "Image cache was populated after CHECKSUM signature failure"
  unset FAKE_CHECKSUM_SOURCE
  pass "Tampered Fedora clearsigned CHECKSUM is rejected before image download or cache publication"

  jq -n '{schema_version:1,keyrings:{vendor:{fingerprints:["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]}}}' > "$PF_IMAGE_TRUST_FILE"
  chmod 0640 "$PF_IMAGE_TRUST_FILE"
  if pf_image_verify_signature "$signature_file" "$signed_payload" vendor >/dev/null 2>&1; then
    fail "Valid signature from an unpinned fingerprint was accepted"
  fi
  pass "valid OpenPGP signature rejected when its signer fingerprint is not pinned"
else
  pass "OpenPGP signing fixture skipped because gpg/gpgv is unavailable"
fi

pass "Image Manager hermetic tests completed; no real network or Proxmox command used"
