# ProxForge Phase 4 — Proxmox VE Adapter

## Scope

Phase 4 adds the local-node Proxmox VE adapter. It is loaded by the Core but performs no host commands at source time. The default CLI diagnostic commands are read-only.

The adapter targets Proxmox VE 9.2 or newer and Bash 5.1+. The supported host-side tools are pveversion, pvesh, qm, pvesm, ip, qemu-img, sha256sum and sha512sum.

## Read-only discovery

- pf_pve_init verifies root execution, the installed Proxmox version and the online local node.
- pf_pve_refresh_inventory reads the cluster node list, storage definitions/status, cluster guest resources and Linux bridges.
- Storage is eligible for VM images only when it is enabled, active on the local node and advertises the images content type.
- Bridge discovery uses ip -j link show type bridge on the local node and only marks an interface active when the link is UP.
- VMID availability is checked against cluster-wide VM and container resources. /cluster/nextid is a suggestion and is checked again before use.

Read-only CLI:

    ./proxforge.sh pve doctor
    ./proxforge.sh pve nodes
    ./proxforge.sh pve storages
    ./proxforge.sh pve bridges
    ./proxforge.sh pve vmid next

## VM and disk primitives

The adapter exposes these functions for the later VM Lifecycle and Operations phases:

- pf_pve_vm_create <vmid> <name> <storage> <bridge> <profile-json>
- pf_pve_vm_import_disk <vmid> <verified-image-path> <storage>
- pf_pve_vm_attach_imported_disk <vmid> scsi0 <exact-imported-volume-id>
- pf_pve_vm_configure_cloudinit <vmid> <storage>
- pf_pve_vm_start <vmid>

VM creation applies the closed Phase 1 profile contract: q35, OVMF, VirtIO SCSI, VirtIO networking, QEMU Guest Agent selection and an EFI variables disk. Secure Boot profile settings are represented by EFI pre-enrolled keys. New VMs are tagged proxforge and are not started by pf_pve_vm_create.

Disk import is allowed only from an image path returned by the Image Manager in the same Bash process. Before import, the adapter checks the sidecar contract, file size, configured size limit, SHA-256/SHA-512 digest, actual qemu-img format and current checksum trust policy. After qm importdisk, it reads the VM configuration again and requires exactly one new unused[n] volume on the requested storage. It does not guess the volume name or attach it automatically.

Only the exact unused volume returned by the import function in the same process may be attached to scsi0. Cloud-Init configuration requires an attached scsi0 and active image-capable storage. Starting a VM is a separate explicit call and is allowed only for a proxforge-tagged VM with both the system disk and Cloud-Init drive verified.

The adapter does not delete VMs or volumes, perform automatic rollback, force-stop guests, modify node networking or change storage configuration. These require ownership-aware orchestration in later phases.

## Safety and reconciliation

- All command arguments are passed as individual Bash arguments; no eval or shell command-string construction is used.
- Node, VMID, storage, bridge, VM name, profile and imported volume identifiers are validated before host calls.
- Mutations are followed by a Proxmox API read to verify the resulting configuration/status.
- If a mutation succeeds but its post-read cannot be verified, the adapter reports that manual reconciliation is required and does not attempt an automatic delete.
- VM modifications require the proxforge management tag.
- PF_PVE_TEST_MODE=1 bypasses the root check only. It must never be enabled in production.

## Test boundary

Run:

    ./tests/run-tests.sh

The Proxmox adapter test suite uses mock pveversion, pvesh, ip and qm commands plus a synthetic image and metadata sidecar. It does not require root, a cluster or a real Proxmox host. No real VM creation, disk import or start is performed by CI.
