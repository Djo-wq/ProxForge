# Fedora trusted keyring

The Fedora module verifies Fedora's OpenPGP clear-signed CHECKSUM files.

The public key bundle is intentionally not committed to this repository.
Provision it on the Proxmox host as root:

    bash scripts/provision-fedora-keyring.sh

The provisioning script downloads https://fedoraproject.org/fedora.gpg,
checks that it contains both full fingerprints pinned in ../keyrings.json,
then installs it as fedora-release.gpg with root ownership and mode 0640.

The Image Manager independently checks the actual signing fingerprint for
every downloaded CHECKSUM. Additional public keys in Fedora's bundle are not
automatically trusted: only fingerprints listed under keyrings.fedora-release
in ../keyrings.json are accepted.

The currently pinned release keys are:

- Fedora 45: 4F50A6114CD5C6976A7F1179655A4B02F577861E
- Fedora 44: 36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6

Fingerprint source: https://fedoraproject.org/en/security/
