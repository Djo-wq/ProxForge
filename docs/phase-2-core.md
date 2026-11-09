# ProxForge Phase 2 — Core Foundation

## Implemented

- Bash 5.1+ bootstrap with deterministic component load order.
- Common logging and public CLI error-code constants.
- JSON configuration loading with strict key/type/range validation.
- Configuration overrides that preserve explicit false values.
- Local distribution module loader with API, identity, metadata and required-function checks.
- Module stdout rejection and structured result validation for release lists, release resolutions and image descriptors.
- Declarative profile listing/loading and path traversal rejection.
- Read-only Phase 2 CLI commands: version, help, profile list/show and config show.
- Hermetic tests with command mocks that fail if a Proxmox/QEMU command is invoked.

## Trust model

Modules are sourced Bash code and are fully trusted code. The loader does not sandbox them. In production, the distributions directory, module directory and module file must be root-owned and not group/world writable. PF_CORE_TEST_MODE=1 disables ownership checks only for local fixture tests; it must never be set in production.

## Not implemented in this phase

- Production Fedora and Debian modules.
- Image downloads, checksums, signatures, cache publication or cleanup.
- Proxmox Adapter and any VM creation or deletion.
- Operation manifests, locks and rollback.
- Full CLI and doctor command.

Phase 2 tests establish the Core foundation only. They are not Proxmox integration tests.

## Test

Run from the repository root:

    ./tests/run-tests.sh

Runtime dependencies for these Core checks: Bash 5.1+, jq, grep, stat and mktemp. Tests use temporary files and local fixture modules and do not require root or a Proxmox node.
