# ProxForge Phase 3 — Image Manager

## Delivered scope

The Image Manager is a Core component and can be loaded without starting a download. Its acquisition entry point is:

    pf_image_acquire <distribution-id> <validated-image-descriptor-json>

The descriptor is the Module API v1 result from pf_distro_get_image. On success, the function returns the verified local path in PF_IMAGE_PATH, the validated sidecar in PF_IMAGE_METADATA_JSON, and whether the content was already cached in PF_IMAGE_CACHE_HIT.

## Security policy

- Direct HTTPS files only; archives and HTTP are not supported.
- Exact hostname allow-lists apply to the image, checksum, signature and every redirect hop.
- Redirects are handled manually; curl does not follow them automatically.
- User-info, non-HTTPS URLs and non-standard ports are rejected.
- Image and checksum sizes are bounded.
- Checksums are SHA-256 or SHA-512, and the checksum file must contain exactly one entry for the expected filename.
- A signed-checksum descriptor requires a detached OpenPGP signature. gpgv must validate it and its signing fingerprint must match a separately pinned registry entry.
- The trusted keyring registry lives in trust/keyrings.json. The matching binary keyring lives in trust/keyrings/<id>.gpg. Both, and their directories, must be root-owned and not group/world writable at runtime.
- The repository intentionally ships an empty keyring registry. No vendor fingerprint is approved until it has been obtained from and independently checked against an authoritative publisher source.
- Official-TLS checksums are disabled by default. Setting allow_official_tls_checksum=true explicitly opts into a weaker trust level.
- The cache is content-addressed by the verified digest and protected by per-image flock locks.
- Images and JSON metadata are staged privately and published with no-overwrite hard links on the same filesystem.
- Existing incomplete or inconsistent cache entries are rejected and left untouched; automatic deletion or repair is not attempted.
- A cache hit re-downloads and re-verifies publisher checksum/signature material, then rechecks the file digest and qemu-img format.
- The Image Manager never calls qm, pvesh or pct. Import remains the future Proxmox Adapter's responsibility.

## Configuration additions

| Key | Default | Purpose |
|---|---:|---|
| image_max_bytes | 107374182400 | Maximum image size (100 GiB) |
| image_download_timeout_seconds | 14400 | Per-request timeout |
| image_lock_timeout_seconds | 1800 | Maximum wait for another cache process |

The existing allow_official_tls_checksum flag remains false by default.

## Trusted OpenPGP key provisioning

No publisher keys are automatically downloaded, and the empty keyring registry is intentional. Before using a signed-checksum descriptor:

1. Obtain the publisher's signing key and full fingerprint from an authoritative publisher channel and independently verify that fingerprint.
2. Build the ProxForge keyring file at trust/keyrings/<id>.gpg using that verified key material.
3. Add the exact full fingerprint (40 or 64 hexadecimal characters) under keyrings.<id>.fingerprints in trust/keyrings.json.
4. Ensure the trust directory, registry, keyrings directory and keyring file are root-owned and not group/world writable on the Proxmox host.

Never copy a fingerprint from an unverified download or a third-party mirror. A keyring file containing multiple keys is permitted, but only a VALIDSIG fingerprint pinned in the registry is accepted.

## Dependencies

Core runtime dependencies remain Bash 5.1+, jq, grep, stat and mktemp. Image acquisition additionally requires curl, flock, sha256sum, sha512sum, qemu-img, date and awk. Signature verification additionally requires gpgv. The Image Manager checks these tools only when an image operation is requested.

## Boundaries and known limitations

- Only x86_64, direct RAW and QCOW2 images are supported by API v1.
- No archive extraction, mirror discovery, automatic key rotation or keyring download is implemented.
- The operator must provision publisher keyrings and fingerprints after independent verification.
- No Proxmox VM import, operation journal or rollback is implemented in this phase.
- qemu-img info validates the declared disk format and non-zero virtual size; it does not independently prove guest operating-system architecture or Cloud-Init capability.
- The Core and Image Manager are trusted root-level components. Modules are sourced Bash and remain trusted code, not sandboxed extensions.

## Tests

Run:

    ./tests/run-tests.sh

The Image Manager suite uses fake local curl and qemu-img commands. It does not contact public mirrors, download real operating-system images or invoke Proxmox commands.
