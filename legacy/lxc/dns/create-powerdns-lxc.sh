#!/usr/bin/env bash
set -Eeuo pipefail

# ARCHIVE NOTICE
# The historical PowerDNS script was already truncated in the repository:
# its final command contains an unterminated string and the remainder of the
# installer is missing. Its intended behavior cannot be reconstructed safely.
# Keep this compatibility path inert until a complete replacement is reviewed.

printf '%s\n' '[ERROR] This archived PowerDNS script is incomplete and cannot be executed.' >&2
printf '%s\n' '[INFO] Use a reviewed ProxForge module or a separately maintained installer.' >&2
exit 1
