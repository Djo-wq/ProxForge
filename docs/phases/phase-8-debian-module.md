# ProxForge Phase 8 — Debian Cloud module

## Scope

The Debian module implements Module API v1 for the current stable Debian Cloud image. Its initial catalog is deliberately limited to Debian 13 (Trixie), x86_64, and the `generic` QCOW2 image.

| Debian series | Current point release | Status | Cloud image |
|---|---:|---|---|
| 13 (Trixie) | 13.7 | stable / supported | debian-13-generic-amd64.qcow2 |

The accepted selectors are `latest`, `stable`, `trixie`, `13`, `13.x`, and `13.7`. They resolve to the Debian 13 stable image track. Debian 12, testing (`forky`), unstable (`sid`), unlisted releases, and non-x86_64 targets are rejected.

The Debian 13 release lifecycle recorded by the module is:

- Initial release: 2025-08-09.
- Current point release at module authoring: 13.7, released 2026-09-12.
- Full Debian support through 2028-08-09.
- Long Term Support through 2030-06-30.

These are Debian release lifecycle dates, not a promise that every CPU architecture remains supported throughout the full LTS period.

## Image selection

The module uses Debian's `generic` image rather than `genericcloud`. Debian documents `generic` as suitable for any cloud-init-capable environment and lists plain VM / QEMU as a supported cloud environment. `genericcloud` is the smaller-driver variant and is not selected for this initial Proxmox profile.

The canonical directory is:

    https://cloud.debian.org/images/cloud/trixie/latest/

The image filename is `debian-13-generic-amd64.qcow2`; its SHA-512 entry is read from `SHA512SUMS` in the same directory. The `latest` directory is intentionally used so Debian can refresh the Cloud image without requiring a module filename change. The point release label and the latest Cloud image build are separate concepts.

Only the canonical Debian image host and the official Debian CDN host are included in the HTTPS redirect allowlist. The Image Manager checks every redirect hop against that exact allowlist.

## Integrity and trust policy

Debian's Cloud Team documents TLS download of current per-distribution Cloud images and checksum files from Debian's Cloud/CD image hosts. It distinguishes these current images from legacy OpenStack images, which publish detached checksum signatures.

The current Debian Cloud descriptor therefore uses:

- Direct HTTPS QCOW2 file; no archive extraction.
- SHA-512 from the exact `SHA512SUMS` entry for `debian-13-generic-amd64.qcow2`.
- `official-tls-checksum` verification with `official_tls` trust metadata.
- No detached signature or invented OpenPGP keyring.

ProxForge sets `allow_official_tls_checksum` to `false` by default. Debian image acquisition is deliberately blocked until an operator explicitly opts in to this trust mode in the ProxForge configuration. This is weaker than a detached signature verified against an independently pinned key, and must not be described as signed-checksum verification.

At acquisition, the Image Manager downloads the checksum file, parses exactly one SHA-512 entry for the expected filename, downloads the image from the allow-listed HTTPS origin, verifies SHA-512, validates QCOW2 with `qemu-img`, and publishes the image and sidecar metadata using the existing content-addressed cache. On cache hits, it re-downloads the checksum material and repeats checksum and disk-format verification.

Official references:

- Debian releases and lifecycle: https://www.debian.org/releases/trixie/
- Debian 13.7 release announcement: https://www.debian.org/News/2026/20260912
- Debian Official Cloud Images and integrity guidance: https://www.debian.org/cloud/
- Official Debian Cloud image directory: https://cloud.debian.org/images/cloud/trixie/latest/

## Module contract

The module exposes the standard five Module API v1 functions: initialization, release listing, release resolution, image descriptor generation, and image validation.

The image descriptor declares `NoCloud` as the Cloud-Init datasource used by the Proxmox Cloud-Init path. The validation function independently checks the sidecar distribution, release, architecture, expected filename, source URL prefix, QCOW2 format, official-TLS trust metadata, file size, and SHA-512 digest.

## Tests

Run the complete hermetic suite:

    bash tests/run-tests.sh

The Debian module tests cover release resolution, rejection of unlisted releases and architectures, descriptor shape, explicit refusal while official-TLS verification is disabled, and local SHA-512 metadata validation.

The Image Manager integration test uses a synthetic Debian QCOW2 fixture and a mocked HTTPS client to exercise SHA-512 parsing, digest verification, QCOW2 inspection, cache publication, and cache-hit revalidation.

No real Debian image is downloaded and no real Proxmox VM is created, started, or deleted by these tests.

## Boundaries

- Only Debian 13 Trixie stable, x86_64 and the generic QCOW2 image are exposed in this phase.
- The module does not dynamically resolve Debian testing, unstable, Bookworm, ARM64 or other architectures.
- Current official Cloud image checksums are verified using HTTPS transport trust and SHA-512; no detached signature is claimed.
- `allow_official_tls_checksum=true` is an explicit operator trust decision and is not enabled by this phase.
- No production download or VM deployment has been run by the hermetic tests.
