#!/usr/bin/env bash
PF_MODULE_API_VERSION="1"
PF_MODULE_ID="invalid-metadata"
PF_MODULE_NAME=""
PF_MODULE_FAMILY="debian"
PF_MODULE_VERSION="1.0.0"
PF_MODULE_ARCHES=("x86_64")
pf_distro_init() { return 0; }
pf_distro_list_releases() { PF_MODULE_RESULT_JSON='[{"version":"1","channel":"stable","status":"supported"}]'; }
pf_distro_resolve_release() { PF_MODULE_RESULT_JSON='{"version":"1","channel":"stable","status":"supported"}'; }
pf_distro_get_image() { PF_MODULE_RESULT_JSON='{}'; }
pf_distro_validate_image() { return 0; }