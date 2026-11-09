#!/usr/bin/env bash
PF_MODULE_API_VERSION="1"
PF_MODULE_ID="valid"
PF_MODULE_NAME="Valid fixture"
PF_MODULE_FAMILY="redhat"
PF_MODULE_VERSION="1.0.0"
PF_MODULE_ARCHES=("x86_64")

pf_distro_init() {
  return 0
}

pf_distro_list_releases() {
  PF_MODULE_RESULT_JSON='[{"version":"1.0","channel":"stable","status":"supported","release_date":"2026-01-01"}]'
}

pf_distro_resolve_release() {
  PF_MODULE_RESULT_JSON='{"version":"1.0","channel":"stable","status":"supported","release_date":"2026-01-01"}'
}

pf_distro_get_image() {
  PF_MODULE_RESULT_JSON='{
    "url":"https://images.example.invalid/fixture-1.0.qcow2",
    "filename":"fixture-1.0.qcow2",
    "allowed_hosts":["images.example.invalid"],
    "download_format":"file",
    "archive_format":"none",
    "disk_format":"qcow2",
    "architecture":"x86_64",
    "release":"1.0",
    "checksum":{"url":"https://images.example.invalid/SHA256SUMS","algorithm":"sha256","filename":"SHA256SUMS"},
    "signature":null,
    "verification":{"method":"official-tls-checksum","trust_level":"official_tls"},
    "cloud_init":{"status":"verified","datasource":"NoCloud"}
  }'
}

pf_distro_validate_image() {
  [[ -s "$1" ]] || return 1
  jq -e '.schema_version == 1' "$2" >/dev/null
}