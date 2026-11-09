# ProxForge — Phase 1: contracts and schemas

**Contract revision:** Module API v1  
**Core target:** ProxForge 1.0.0  
**Schema revision:** 1  
**Status:** Design baseline. This document does not claim a working Core or operational distribution module.

## 1. Scope

Phase 1 freezes the interfaces shared by the Core, distribution modules, profiles, image cache and operation journal. Distribution modules shipped with ProxForge are trusted local Bash code. They are not plugins, are not downloaded dynamically and are not sandboxed.

Fedora and Debian must use the same functions and data conventions. Distribution-specific image discovery remains inside the module; VM lifecycle and all Proxmox mutations remain in the Core and Proxmox Adapter.

## 2. Module identity and versioning

Each module is shipped as \`distributions/<id>/module.sh\` and declares:

- \`PF_MODULE_API_VERSION="1"\`
- \`PF_MODULE_ID\`: stable lowercase identifier, equal to the module directory name.
- \`PF_MODULE_NAME\`: display name.
- \`PF_MODULE_FAMILY\`: \`redhat\` or \`debian\` for the initial distributions.
- \`PF_MODULE_VERSION\`: semantic version of the module itself, independent of Core and distribution releases.
- \`PF_MODULE_ARCHES\`: Bash indexed array of supported ProxForge architecture names. V1 supports \`x86_64\`.

The Core projects these globals into the JSON object defined by \`schemas/module.schema.json\` and validates it before calling the module. Missing metadata, wrong directory identity, incompatible API version, missing functions, unsupported architecture and malformed result JSON are fatal errors.

The module API version is independent of Core, configuration, cache and operation schema versions. An incompatible contract change requires an explicit API version decision.

## 3. Required functions

All five functions are mandatory and are called in the current Bash process, not via command substitution.

### \`pf_distro_init\`

No positional arguments. Performs module-local initialization and consistency checks. Returns zero on success and non-zero on failure. It does not need to populate result JSON.

### \`pf_distro_list_releases\`

No positional arguments. On success sets \`PF_MODULE_RESULT_JSON\` to a non-empty JSON array. Each entry contains:

- \`version\`: canonical release identifier (string).
- \`channel\`: \`stable\`, \`testing\`, \`beta\`, \`rawhide\` or \`archived\`.
- \`status\`: \`supported\`, \`maintenance\`, \`eol\`, \`archived\` or \`unknown\`.
- \`release_date\`: optional verified publication date.
- \`support_lifecycle\`: optional object with sourced lifecycle details.

An unknown lifecycle must never be labelled supported.

### \`pf_distro_resolve_release <requested>\`

Accepts \`latest\`, \`stable\` or an explicit release identifier. On success sets result JSON to one object containing canonical \`version\`, \`channel\` and \`status\`; \`release_date\` and \`support_lifecycle\` are optional.

\`latest\` and \`stable\` resolve to the newest stable release eligible and supported under the module's documented policy. They never resolve to Beta, Rawhide or another pre-release. An explicitly requested historical release may be returned with its real lifecycle status; it must never be relabelled supported.

### \`pf_distro_get_image <version> <architecture>\`

Accepts a canonical release and supported architecture. On success sets result JSON to one image descriptor containing:

- \`url\`: HTTPS image URL.
- \`filename\`: basename only; no path separators or traversal components.
- \`allowed_hosts\`: non-empty list of exact hostnames permitted for the initial URL and redirects.
- \`download_format\`: \`file\` in V1.
- \`archive_format\`: \`none\` in V1.
- \`disk_format\`: \`qcow2\` or \`raw\`.
- \`architecture\`: ProxForge architecture name (\`x86_64\` in V1).
- \`release\`: canonical release identifier.
- \`checksum\`: object with HTTPS \`url\`, \`algorithm\` (\`sha256\` or \`sha512\`) and \`filename\`.
- \`signature\`: null if the publisher has no detached signature; otherwise object with HTTPS \`url\`, \`format\` (\`openpgp\`) and \`keyring_id\`.
- \`verification\`: \`method\` (\`signed-checksum\` or \`official-tls-checksum\`) and \`trust_level\` (\`signed\` or \`official_tls\`).
- \`cloud_init\`: \`status\` (\`verified\`, \`unverified\` or \`unsupported\`) and optional \`datasource\`.

The descriptor records what the module knows about the publisher. It is not proof that a later download is safe. The Image Manager independently enforces HTTPS, allowed-host redirects, checksum and signature verification, size limits and the configured trust policy. An official checksum obtained over TLS is not equivalent to a signed checksum. An image with no acceptable verification method is refused by default.

The module does not download the image into a VM or import it. Downloading, caching, verification and disk import are Core responsibilities.

### \`pf_distro_validate_image <image_path> <metadata_json_path>\`

Receives the local image and validated cache metadata JSON. Performs distribution-specific compatibility checks that cannot be handled generically. Returns zero only when those checks pass. It must not mutate Proxmox or the image. Core-level digest, actual disk format, architecture (where detectable) and cache metadata checks remain mandatory and are not delegated to the module.

## 4. Result transport and shell behavior

Before every function call, the Core initializes \`PF_MODULE_RESULT_JSON=""\`. Functions returning structured data set it to exactly one valid JSON value. The Core validates it with \`jq\` immediately after the call.

- Call functions directly in the current shell. Do not use \`$(...)\` to collect a function result.
- Return status is numeric: zero means success; any non-zero value means failure.
- Standard output is reserved and must remain empty for every contract function.
- Human-readable diagnostics go to standard error.
- A result-producing function must not leave the result variable empty or malformed.
- Functions must not call \`exit\`, replace Core functions or modify variables reserved to \`PF_CORE_*\`.
- Modules should not change working directory, shell options, traps or umask.
- Do not use \`eval\`, dynamically downloaded executable modules or remote \`source\`.

The contract tests call functions in the current shell with stdout redirected to a temporary file, then inspect the result variable. This catches accidental output without losing state in a subshell.

## 5. Trust and privilege boundary

A module sourced by Bash is fully trusted code running with ProxForge privileges. Sourcing is not isolation or sandboxing. For V1:

- Only modules shipped with the ProxForge installation are accepted.
- Module files and parent directories must be owned by root and not writable by unprivileged users.
- Modules are reviewed before release.
- Third-party module discovery and dynamic module download are unsupported.
- Only one distribution module is loaded for one operation.

This is a security constraint, not an implementation detail.

## 6. Profile contract

Profiles are declarative JSON only. They cannot contain shell commands, arbitrary \`qm\` arguments, hooks, templates or distribution-specific behavior. The allowed hardware settings are closed by \`schemas/profile.schema.json\`.

| Profile | CPU cores | Memory (MiB) | Disk (GiB) |
|---|---:|---:|---:|
| Minimal | 1 | 1024 | 8 |
| Standard | 2 | 2048 | 20 |
| Server | 4 | 4096 | 40 |
| Heavy | 8 | 8192 | 100 |

These are initial presets, not universal sizing recommendations. Explicit CLI values will override profile values in the later Core configuration merge.

## 7. Image cache metadata contract

Each verified cached image has a JSON sidecar conforming to \`schemas/image-metadata.schema.json\`. It records publication identity, source URL, safe filename, architecture, actual disk format, file size, digest, verification method and timestamps.

An image file's presence in cache is not evidence of integrity. The Image Manager rechecks metadata and digest before use. V1 accepts direct RAW or QCOW2 files; general archive extraction is out of scope.

Only two verification levels are represented:

- \`signed-checksum\` / \`signed\`: checksum signature verified with an independently trusted key, fingerprint checked, and image digest matched.
- \`official-tls-checksum\` / \`official_tls\`: checksum fetched from an approved official HTTPS host and matched, without claiming an independent publisher signature.

There is no schema value for an unverified image: it is not eligible as a usable cached image.

## 8. Operation and event contract

An operation manifest conforms to \`schemas/operation.schema.json\`; each JSON line in \`events.jsonl\` conforms to \`schemas/operation-event.schema.json\`. The manifest stores operation identity, VMID, node, selected distribution/release/profile, image digest, storage, exact created resource identifiers and rollback state.

A created resource record stores the exact Proxmox VolID (when applicable), storage, role, slot and whether ownership was verified. Names and descriptions are correlation hints, not ownership proof.

The state enum follows the lifecycle in the project specification. Every mutating Proxmox action must be preceded by an intent event and followed by verification of actual Proxmox state. Rollback is allowed only for resources whose ownership is demonstrated. Ambiguous or externally modified resources are retained and reported.

## 9. Error and compatibility policy

Module functions use a simple status contract: \`0\` success, non-zero failure. The Core maps failures to the documented public CLI exit codes; module-specific status numbers are diagnostic only and do not become undocumented CLI semantics.

Unknown API/schema versions, enum values, fields, architectures and malformed JSON are rejected. Schema changes require a documented compatibility decision and a version increment when incompatible. Existing config, cache and operation files are never overwritten as an implicit migration.

## 10. Tests and Phase 1 boundary

Run isolated contract checks with \`./tests/run-tests.sh\`.

Phase 1 tests use only local fixture modules, temporary files and \`jq\`. They do not call Proxmox, download images or load code from the network. Fixtures cover a valid module and invalid modules (missing function, incompatible API, missing metadata, unexpected stdout and malformed JSON).

These tests establish the contract only. They do not claim that a production Core, Fedora module, Debian module, cache manager, Proxmox integration or VM deployment exists.
