#!/bin/bash
# config-loader.sh — Configuration loading and validation helpers for entrypoint.

require_config_key() {
    local key="$1"
    local value="${!key:-}"

    [[ -n "${value}" ]] || die "Required key '${key}' is missing or empty"
}

load_config_file() {
    local config_file="$1"

    [[ -f "${config_file}" ]] || die "Configuration file not found: ${config_file}"

    # Config files are repository-owned shell-style key=value fragments.
    # shellcheck source=/dev/null
    source "${config_file}"
}
