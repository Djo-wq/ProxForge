# ProxForge Phase 7 — Fedora Cloud module

## Scope

The Fedora module implements Module API v1 for Fedora Cloud Base Generic images. It currently exposes a deliberately pinned x86_64 QCOW2 catalog:

| Fedora | Lifecycle label | Image revision | Image filename |
|---|---|---:|---|
| 45 | current stable / supported | 1.4 | Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2 |
| 44 | previous stable / maintenance | 1.7 | Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2 |

`latest` and `stable` resolve to Fedora 45. Explicit release selector `44` remains available. Unknown, unpinned and non-x86_64 targets are rejected instead of guessing a mirror or image filename.

The image and CHECKSUM URLs are under:

    https://dl.fedoraproject.org/pub/fedora/linux/releases/<release>/Cloud/x86_64/images/

The image descriptor uses a direct QCOW2 file, SHA-256, the exact CHECKSUM filename, and a verified NoCloud capability declaration.

## Signature verification

Fedora publishes a clear-signed OpenPGP CHECKSUM document rather than a detached `.sig` file. The descriptor therefore identifies the signature format as `openpgp-clearsigned-checksum` and points the signature URL at the CHECKSUM URL.

The Image Manager:

1. Downloads the signed CHECKSUM document over HTTPS from the allow-listed Fedora host.
2. Calls `gpgv` with the provisioned Fedora keyring and asks it to write authenticated plaintext to a private staging file.
3. Reads the primary-key fingerprint from GPGV's VALIDSIG status and requires an exact match in `trust/keyrings.json`.
4. Parses exactly one SHA-256 entry for the expected QCOW2 filename from the authenticated plaintext.
5. Downloads the image, checks its SHA-256 and QCOW2 format, then publishes the verified image and metadata atomically.

The same signed CHECKSUM is re-downloaded and re-verified on cache hits. A tampered signature or a signer that is not pinned blocks acquisition before image publication.

Official references:

- Fedora Cloud downloads and signed CHECKSUM verification: https://fedoraproject.org/cloud/download
- Fedora OpenPGP signing keys and fingerprints: https://fedoraproject.org/en/security/
- Fedora public key bundle: https://fedoraproject.org/fedora.gpg

## Provision the trusted keyring

The repository pins the Fedora 45 and Fedora 44 primary fingerprints in `trust/keyrings.json`. The binary public keyring is not committed. Provision it on the Proxmox host as root:

    bash scripts/provision-fedora-keyring.sh

The script downloads Fedora's public key bundle over HTTPS, confirms that both fingerprints already pinned in the repository are present in that bundle, and installs it as:

    trust/keyrings/fedora-release.gpg

The installed file is root-owned and mode 0640. The Image Manager independently checks the signer fingerprint for every CHECKSUM. Extra keys in the downloaded Fedora bundle do not become trusted merely by being present: only the two fingerprints in `trust/keyrings.json` are accepted.

Before a Fedora deployment, confirm that the provisioning script completed successfully and that the ProxForge trust directory, keyring file and fingerprint registry meet the runtime ownership and permissions policy.

## Tests

Run the complete hermetic suite:

    bash tests/run-tests.sh

The Fedora module tests exercise release resolution, image descriptors, architecture and release rejection, and image metadata/digest validation. The Image Manager tests generate a temporary OpenPGP key, create a clear-signed CHECKSUM fixture, verify authenticated plaintext, test signature re-verification on cache hits, and reject a tampered CHECKSUM.

The tests use synthetic image bytes and mocked HTTP and QEMU commands. They do not download Fedora images or create, start, or delete a real Proxmox VM.

## Boundaries

- Only Fedora Cloud Base Generic x86_64 QCOW2 images for the pinned releases are exposed.
- The release catalog and image revisions are intentionally pinned in the module; they are not dynamically scraped at runtime.
- ARM64, raw images, arbitrary Fedora releases and Rawhide are not exposed by this module.
- Provisioning the trusted public keyring is a separate operator action and is required before image acquisition.
- No real Proxmox VM lifecycle is executed by the module tests.
