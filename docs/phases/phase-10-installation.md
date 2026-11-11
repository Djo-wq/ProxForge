# ProxForge Phase 10 — Installation and Configuration

## Scope

Phase 10 adds a root-operated installer and uninstaller for the modular ProxForge CLI. The installer is deliberately limited to Proxmox VE 9.2 or newer on Debian 13. It does not create VMs, change Proxmox storage or network configuration, install a service, or modify `main`.

## Host requirements

The system installer requires:

- Proxmox VE 9.2 or newer on Debian 13, with `/etc/pve` present;
- root privileges and Bash 5.1 or newer;
- `jq`, `curl`, `flock`, `qemu-img`, `sha256sum`, `sha512sum`, `gpgv`, `qm`, `pvesh`, `pvesm`, `pveversion` and `ip`.

The installer checks the host before writing the managed installation. Missing optional userspace dependencies can be installed through Debian's package manager with the explicit `--install-dependencies` flag. This flag runs `apt-get update` and installs `jq`, `curl`, `util-linux`, `qemu-utils`, `coreutils`, `gpgv`, `gnupg` and `iproute2`. Proxmox-specific commands are never installed or replaced by this step.

## Installation

From the checked-out repository on the Proxmox node:

```bash
sudo bash scripts/install.sh
```

To allow the installer to install the documented Debian packages when needed:

```bash
sudo bash scripts/install.sh --install-dependencies
```

To additionally download Fedora's official public key bundle and validate it against the repository's pinned fingerprints:

```bash
sudo bash scripts/install.sh --provision-fedora-keyring
```

Key provisioning is not performed implicitly. Without the flag, the installed provisioning script is available at `/usr/local/lib/proxforge/scripts/provision-fedora-keyring.sh` and can be run later as root. The installer never changes the Debian official-TLS checksum opt-in setting.

## Managed filesystem layout

| Path | Purpose | Default permissions |
| --- | --- | --- |
| `/usr/local/lib/proxforge` | CLI, Core, modules, schemas, profiles and scripts | root-owned, directories `0755`, files `0644` |
| `/usr/local/bin/proxforge` | CLI entry point (relative symlink) | managed symlink |
| `/usr/local/bin/proxforge.sh` | Backward-compatible CLI entry point | managed symlink |
| `/etc/proxforge` | Persistent configuration | root-owned `0750` |
| `/etc/proxforge/config.json` | Initial JSON configuration | root-owned `0640` |
| `/var/lib/proxforge/cache` | Verified image cache | root-owned `0750` |
| `/var/lib/proxforge/tmp` | Temporary downloads and work files | root-owned `0700` |
| `/var/lib/proxforge/state` | Operation journals and state | root-owned `0700` |
| `/var/log/proxforge` | Application logs | root-owned `0750` |

The first installation copies `config/defaults.json` to `/etc/proxforge/config.json`. On subsequent installations, an existing regular configuration file is preserved and validated; an invalid configuration aborts the installation rather than being overwritten. The CLI continues to merge this file over its built-in defaults and rejects unknown keys.

The installer builds the application tree in a temporary directory on the same filesystem and validates the effective configuration before switching it into place. A managed-install manifest protects unrelated directories from accidental replacement. Existing locally provisioned Fedora key material is preserved during upgrades. The installer does not follow symbolic links in managed paths or in its source trees.

Custom paths configured for image cache, temporary files, state or logs remain administrator-managed. The installer creates the standard ProxForge directories above; it does not create arbitrary paths supplied by a JSON file.

## Diagnostics and configuration

```bash
proxforge --version
proxforge doctor
proxforge config show
proxforge config validate
```

Use `--config FILE` to validate an alternate configuration before making it active:

```bash
proxforge --config /root/proxforge-test.json config validate
```

The install step only prepares the filesystem and verifies prerequisites. It does not invoke `deploy`, `qm create`, or any other VM mutation.

## Upgrade

Run the same installer from the new checkout. It replaces only a previously managed `/usr/local/lib/proxforge` tree, retains `/etc/proxforge/config.json`, retains the cache/state/log directories, and copies the existing provisioned Fedora keyring into the new software tree. If the staged CLI or existing config fails validation, the old software tree remains in place.

## Uninstallation

The default uninstaller removes the application files and managed CLI links but preserves configuration and runtime data:

```bash
sudo bash /usr/local/lib/proxforge/scripts/uninstall.sh
```

To remove configuration, request it explicitly. The complete `/etc/proxforge` directory is first archived under `/var/backups/proxforge` with mode `0600`:

```bash
sudo bash /usr/local/lib/proxforge/scripts/uninstall.sh --remove-config
```

To also remove image cache, operation state, temporary data and logs:

```bash
sudo bash /usr/local/lib/proxforge/scripts/uninstall.sh --remove-config --remove-data
```

`--remove-data` is destructive and must be explicitly supplied. The uninstaller verifies the installation manifest before deleting application files and removes only CLI symlinks whose targets match ProxForge's relative entry-point target.

## Staging and tests

The `--prefix ABSOLUTE_DIRECTORY` option is exclusively for package staging and hermetic tests. It writes the same filesystem layout below the chosen directory, skips root/Proxmox host checks, and does not modify live `/etc`, `/var` or `/usr/local` paths.

```bash
bash scripts/install.sh --prefix /tmp/proxforge-stage
bash scripts/uninstall.sh --prefix /tmp/proxforge-stage
bash tests/run-tests.sh
```

The Phase 10 tests exercise staged install, repeat-install behavior, configuration preservation, restricted permissions, uninstall defaults, explicit configuration backup, explicit data removal and invalid-config rollback. They do not contact Proxmox or download operating-system images.
