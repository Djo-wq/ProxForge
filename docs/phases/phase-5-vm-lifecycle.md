# ProxForge Phase 5 — VM Lifecycle Manager

## Scope

Phase 5 adds the VM Lifecycle Manager. It coordinates the existing Core, distribution Module API v1, Image Manager and Proxmox VE Adapter into one journaled VM deployment operation.

The lifecycle component is sourced by Core but performs no host work at source time. A deployment only starts when the explicit CLI command is invoked.

## CLI

Deploy a VM:

    ./proxforge.sh deploy <distribution> <release|stable|latest> <profile> <storage> <bridge> [vm-name] [vmid|auto]

Examples:

    ./proxforge.sh deploy fedora stable standard local-lvm vmbr0
    ./proxforge.sh deploy debian latest server local-lvm vmbr0 db-test 320

Inspect operations:

    ./proxforge.sh operation list
    ./proxforge.sh operation show <operation-uuid>
    ./proxforge.sh operation reconcile <operation-uuid>

The pve doctor, nodes, storages, bridges and vmid next commands remain read-only diagnostics.

## Deployment sequence

1. Validate distribution, release selector, profile, storage, bridge, optional name and optional VMID.
2. Create a UUID-scoped operation directory and record the original request.
3. Verify Proxmox version/node, profile, target storage, and bridge.
4. Load the trusted local distribution module and resolve a supported or maintenance stable release.
5. Resolve the image descriptor and require verified Cloud-Init support.
6. Journal image download intent, acquire the image through the Image Manager, and call the module's image validator.
7. Calculate a SHA-256 operation digest for the manifest. This digest is separate from the publisher checksum algorithm in the image metadata.
8. Acquire a global VMID allocation lock, request or validate a VMID, and persist the Phase 1 operation manifest.
9. Journal VM creation intent, create the VM through the Proxmox Adapter, and persist verified VM ownership.
10. Journal disk import intent, import the verified image and record the exact resulting unused volume.
11. Attach only that volume to scsi0; configure and verify NoCloud Cloud-Init.
12. Start the VM only when start_vm is true in the Core configuration. Otherwise the completed VM remains stopped.
13. Persist the completed state and final event.

The release status must be supported or maintenance and the channel must be stable. Testing, beta, Rawhide, archived, EOL and unknown releases are refused by this lifecycle.

## Operation journal

Each operation lives in:

    <state_dir>/<operation-uuid>/

Files:

- request.json records the original CLI request before image acquisition.
- events.jsonl is an append-only sequence of intent and observed-result events.
- operation.json is the Phase 1 operation manifest. It is written atomically once the image has been verified and before the first VM mutation.
- .lock prevents two processes from using the same operation directory.

The global .vmid-allocation.lock serializes VMID selection and VM creation across ProxForge lifecycle operations.

Event sequence numbers increase monotonically. Intent events are written before VM create, disk import, disk attachment, Cloud-Init configuration and VM start. Success events are written only after the Proxmox Adapter verifies the resulting state.

## Failure and interruption policy

Phase 5 deliberately does not implement destructive rollback. The Operations Manager phase owns rollback and cleanup policy.

- Before the first VM mutation, a failure is journaled as FAILED with rollback status NOT_REQUIRED.
- After a VM mutation may have occurred, a failure is journaled as FAILED with rollback status BLOCKED and a RECONCILIATION_REQUIRED event.
- A VM or volume is recorded as owned only after the Adapter returns a verified result. An uncertain VM creation is recorded with ownership_verified:false when the Adapter can identify the attempted VMID.
- No automatic delete, volume detach, forced stop or retry of an uncertain mutation is performed.
- operation reconcile <uuid> is read-only. It reports the journal state, management tag, VM power state, system-disk presence and Cloud-Init drive presence. It never resumes, deletes or modifies resources.
- An interrupted operation whose image download had not yet produced an operation manifest still retains its request and event journal. It must not be replayed automatically.

## Trust boundaries

- Only the installed trusted distribution module is loaded.
- Only stable releases in supported or maintenance lifecycle status are accepted.
- Image acquisition and verification remain the Image Manager's responsibility.
- The Adapter continues to enforce managed-VM tags, image digest/format checks, exact imported-volume identity and read-after-write verification.
- start_vm is the sole lifecycle switch for automatic VM start. Disk import and Cloud-Init configuration are still performed when it is false.

## Tests

Run:

    ./tests/run-tests.sh

The lifecycle tests use the repository's valid fixture module, a synthetic image and mocked Proxmox Adapter functions. They verify completed deployment, operation journaling, failure after creation, blocked rollback, no-start behavior and read-only reconciliation. No live Proxmox node, public image mirror, VM creation or disk import is used in CI.
