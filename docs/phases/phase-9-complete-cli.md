# ProxForge Phase 9 — Complete CLI

## Goals

Phase 9 completes the operator-facing CLI around the existing Core, distribution modules, Image Manager, Proxmox Adapter, VM Lifecycle Manager and Operations Manager. The CLI is a thin dispatcher: business logic remains in the existing Core components, and read-only commands never invoke a VM mutation.

Every command emits JSON for machine-readable inspection, except help, version and generated Bash completion.

## Global options

    ./proxforge.sh --help
    ./proxforge.sh --version
    ./proxforge.sh --config /etc/proxforge/config.json config show

`--config FILE` selects one explicit JSON override file for that invocation. Its values are merged over `config/defaults.json` and then validated against the strict configuration contract. Unknown keys and invalid values are rejected.

## Local diagnostics

    ./proxforge.sh doctor

`doctor` reports the ProxForge version, Module API version, configuration source, module inventory, root privilege status and required command availability. It exits nonzero when any required host prerequisite is missing. It does not query the Proxmox API; use `pve doctor` for that.

## Profiles

    ./proxforge.sh profile list
    ./proxforge.sh profile show standard

Profile commands read and validate the installed profile JSON files.

## Distribution modules

    ./proxforge.sh module list
    ./proxforge.sh module show fedora
    ./proxforge.sh module releases debian
    ./proxforge.sh module validate fedora
    ./proxforge.sh module image debian latest

`module list` reports module files that meet the local path and ownership requirements. `show` returns the module metadata and release catalog. `releases` returns just the release catalog. `validate` checks the module contract and descriptors for stable supported/maintenance releases; it does not download images. `image` resolves a selector and displays the image descriptor without acquiring it.

For `official-tls-checksum` descriptors, module inspection reports whether the active config currently allows acquisition. It never silently changes `allow_official_tls_checksum`.

## Configuration

    ./proxforge.sh config show
    ./proxforge.sh config path
    ./proxforge.sh config validate
    ./proxforge.sh config validate /etc/proxforge/config.json

`show` returns the effective merged configuration. `path` identifies the defaults or override file currently in use. `validate [FILE]` validates the active config or loads and validates an explicit file without modifying the source file.

## Proxmox diagnostics

    ./proxforge.sh pve doctor
    ./proxforge.sh pve nodes
    ./proxforge.sh pve storages
    ./proxforge.sh pve bridges
    ./proxforge.sh pve vmid next

These commands use the Proxmox Adapter's inventory and validation APIs. They do not create, start, stop or delete VMs.

## Image cache inventory

    ./proxforge.sh image cache list

The cache inventory lists cache files with a readable sidecar, distribution/release/architecture path, file size, checksum algorithm and trust metadata. Its `integrity_state` value `metadata-consistent-not-rehashed` deliberately means the CLI checked path, sidecar structure and size consistency but did not re-compute the image digest. A missing or malformed sidecar is reported as invalid metadata. This command does not repair, delete or overwrite cache entries.

## Deployment

Preferred named options:

    ./proxforge.sh deploy fedora stable standard local-lvm vmbr0 --name fedora-lab --vmid auto
    ./proxforge.sh deploy debian latest server local-lvm vmbr0 --name debian-app --vmid 320

The original positional form remains supported:

    ./proxforge.sh deploy fedora stable standard local-lvm vmbr0 fedora-lab 320

Deployment is still the only CLI command that creates a VM. It runs the Phase 5 lifecycle and Phase 6 operations policies. The CLI does not start a VM unless the effective `start_vm` setting allows it.

## Operations

    ./proxforge.sh operation list
    ./proxforge.sh operation show <operation-uuid>
    ./proxforge.sh operation reconcile <operation-uuid>
    ./proxforge.sh operation rollback <operation-uuid>
    ./proxforge.sh operation resume <operation-uuid>

`reconcile` is read-only. `rollback` uses the ownership-checked Operations Manager. `resume` only creates a new linked operation if the original journal proves that no VM mutation intent was written.

## Bash completion

    source <(./proxforge.sh completion bash)

The generated completion covers the top-level command groups and their subcommands/options.

## Exit codes

CLI argument errors use exit code 2. The application retains the existing Core error-code constants for general, environment, module, image, storage, Proxmox, Cloud-Init, rollback and conflict failures.

## Tests

Run:

    bash tests/run-tests.sh

The new CLI tests cover global help/version, module inventory and inspection, release and image descriptor validation, configuration selection and validation, cache inventory states, completion generation, invalid arguments and the machine-readable doctor result. They use synthetic cache entries and do not access Proxmox or download images.