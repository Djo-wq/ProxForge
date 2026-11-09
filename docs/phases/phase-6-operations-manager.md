# ProxForge Phase 6 — Operations Manager

## Scope

Phase 6 adds the Operations Manager for failure handling, ownership-checked rollback, explicit rollback retry, and safe resumption of interrupted operations before the first VM mutation.

The manager is loaded by Core and performs no host actions at source time. Destructive work is reachable only from an explicit rollback flow or the automatic failure path configured by rollback_mode.

## CLI

Inspect operation state:

    ./proxforge.sh operation list
    ./proxforge.sh operation show <operation-uuid>
    ./proxforge.sh operation reconcile <operation-uuid>

Retry an eligible failed operation's rollback:

    ./proxforge.sh operation rollback <operation-uuid>

Resume an interrupted deployment only when its journal proves no VM mutation was attempted:

    ./proxforge.sh operation resume <operation-uuid>

Resume creates a new operation UUID and links the new manifest and request to the original operation. It does not replay or rewrite the original event journal.

## Automatic rollback policy

When a deployment fails after a VM mutation may have started:

- rollback_mode=auto asks the Operations Manager to attempt guarded rollback.
- rollback_mode=keep preserves the resources and records a BLOCKED result for explicit operator action.
- Completed deployments are not eligible for this failure rollback path.
- An operator may explicitly request rollback of an eligible failed operation even when rollback_mode=keep.

A failed operation is first recorded as FAILED/PENDING before the rollback state machine enters ROLLING_BACK/IN_PROGRESS. Final outcomes are ROLLBACK_COMPLETED/COMPLETED, ROLLBACK_INCOMPLETE/INCOMPLETE, or FAILED/BLOCKED.

## Deletion safety gates

The Proxmox Adapter is the only component that performs destructive Proxmox operations. Before it calls qm destroy or pvesm free, it requires:

1. A valid manifest with exactly one verified ProxForge-owned VM record matching VMID and node.
2. Every resource record to be marked ownership_verified=true and associated with the same VMID.
3. The current VM to exist as a QEMU guest, have the ProxForge management tag, and be stopped. Rollback never force-stops a guest.
4. Successful snapshot inspection and no snapshots other than the current configuration.
5. Exact agreement between current VM disk entries and the manifest. This includes the EFI disk, imported system disk, unused disk slots and Cloud-Init drive.
6. A successful scan of other QEMU and LXC configurations proving that each owned volume is not referenced by another guest.
7. A storage content check confirming that any orphan volume still to be freed reports the expected volid and VMID.

The Adapter first calls qm destroy --purge 1, then refreshes cluster inventory and verifies VM absence. It calls pvesm free only for exact manifest-owned volumes which remain afterward, still report the original VMID in storage content, and have no external guest reference. If any check fails, cleanup is blocked before mutation or marked incomplete after mutation has begun.

The Adapter does not use force-stop, --destroy-unreferenced-disks, broad storage deletion, guessed volume names, or wildcard cleanup. An existing VM disk absent from the ownership manifest blocks the entire cleanup.

Proxmox documents qm destroy as a destructive VM operation and pvesm free as a data-destroying volume operation; the latter is therefore restricted to the exact prevalidated volume ID. References:
- https://pve.proxmox.com/pve-docs/qm.1.html
- https://pve.proxmox.com/pve-docs/pvesm.1.html

## Explicit rollback retry

The operation rollback command loads and validates the operation manifest and event journal, obtains the operation lock, then invokes the same ownership-checked cleanup adapter used by automatic rollback.

A BLOCKED operation can be retried after its precondition is corrected. A ROLLBACK_INCOMPLETE operation can be retried because the Adapter is designed to tolerate an already-absent VM and only inspect exact remaining manifest-owned volumes. The operation journal remains append-only; a retry adds new intent and result events.

## Controlled resume

The operation resume command is intentionally narrower than a generic retry:

- The original operation directory, request and event journal must be safe and readable.
- All event sequence numbers must be contiguous, start at 1, and belong to the same operation UUID.
- If operation.json exists, its identity and schema must match, its created_resources array must be empty, and it must not be terminal or in rollback.
- No VM_CREATE_INTENT, VM_CREATED, DISK_IMPORT_INTENT, DISK_IMPORTED, VM_CONFIGURED, CLOUD_INIT_CONFIGURED, VM_START_INTENT, VM_STARTED or rollback event may be present.
- The original operation lock must be available.
- The replacement deployment revalidates the profile, module, release, image, storage, bridge and VMID before it performs any mutation.

If any VM mutation intent exists, automatic resume is refused even if no VM resource was recorded. This handles the crash window between journaling intent and invoking the Proxmox command. The replacement gets a new operation UUID and has parent_operation_id set to the original UUID.

## Recovery and journaling

The manager validates event JSONL sequence integrity before rollback or resume. It rejects malformed JSON, cross-operation event records, duplicate sequence numbers and sequence gaps.

The operation manifest remains the Phase 1 manifest contract with an optional parent_operation_id field. Resource ownership records include the automatically created EFI disk and Cloud-Init drive in addition to the VM and imported system disk.

The operation reconcile command remains read-only. It reports Proxmox state but never resumes, deletes, starts or reconfigures a VM.

## Tests

Run:

    ./tests/run-tests.sh

New hermetic tests cover:

- Manifest ownership and event-journal integrity.
- Rejection of unverified resources, sequence gaps and cross-operation entries.
- Automatic rollback after a simulated post-creation failure.
- Non-destructive BLOCKED outcome and explicit rollback retry.
- A stopped-VM lifecycle.
- A pre-mutation interrupted operation resumed as a new linked operation.
- Refusal to resume when VM_CREATE_INTENT is present.

CI uses mocked Proxmox operations and synthetic image data. No real Proxmox cluster or VM is altered by these tests.
