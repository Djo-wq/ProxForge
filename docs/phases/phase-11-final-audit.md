# ProxForge Phase 11 — Final audit and stabilization

## Scope

This phase performs a final static and hermetic review of the modular CLI, its installation lifecycle and the safety boundaries around Proxmox operations. It does not claim a live Proxmox deployment test and does not change the `main` branch.

## Finding fixed: installed CLI symlink resolution

The Phase 10 installer publishes `/usr/local/bin/proxforge` and `/usr/local/bin/proxforge.sh` as relative symbolic links to `../lib/proxforge/proxforge.sh`. The CLI previously derived its Core directory from `BASH_SOURCE[0]` directly. When invoked through either installed entry point, that could resolve the script directory as `/usr/local/bin` and make the CLI fail to locate `core/bootstrap.sh`.

The CLI now resolves its actual script path with `readlink -f` before deriving `SCRIPT_DIR`. The installation test invokes both installed symlinks, checks `--version`, and generates Bash completion through the installed command. This closes a production-path regression that a direct invocation of the library copy did not cover.

## Installation and removal safeguards reviewed

- The installer verifies the Proxmox VE 9.2+ / Debian 13 host boundary before a live system install.
- The installer stages files before switching the managed application directory, validates the effective JSON configuration, and refuses to overwrite an unmarked application directory.
- Managed path components and staging prefixes are checked for symbolic links.
- A lock coordinates installer and uninstaller runs.
- Existing administrator configuration is preserved and validated; an invalid file is not overwritten.
- Locally provisioned Fedora key material is copied forward during an upgrade and is never fetched unless the explicit provisioning option is supplied.
- The uninstaller checks its ownership manifest and preflights CLI symlinks before optional configuration backup/removal.
- Configuration removal is opt-in and creates a restricted backup first. Runtime data removal is a separate explicit option.

## Proxmox operation boundary

The Phase 11 validation remains hermetic. The tests do not call a live Proxmox API, create or start a VM, destroy a VM, free a storage volume, or download an operating-system image. The existing Operations Manager, Proxmox Adapter, VM Lifecycle and Image Manager safety tests remain part of the full test runner.

## CI and validation

The Phase 11 workflow now runs:

1. ShellCheck at error severity over the CLI and the install/uninstall/test entry points.
2. Bash syntax checks over the repository's shell scripts.
3. The complete hermetic test suite, including the extended staged installer lifecycle tests.

Run locally with:

```bash
shellcheck --severity=error proxforge.sh scripts/install.sh scripts/uninstall.sh tests/test-install.sh
bash tests/run-tests.sh
```

For the install/uninstall lifecycle specifically:

```bash
bash tests/test-install.sh
```

## Explicitly unverified

A real installation on a Proxmox VE 9.2+ / Debian 13 host, Fedora network key provisioning, and a complete VM deployment lifecycle on physical Proxmox infrastructure require a dedicated test node and operator-controlled validation. They are not inferred from the staging CI result.
