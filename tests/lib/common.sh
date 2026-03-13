#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

info() {
    echo "[INFO] $*"
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
    done
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "This test requires root privileges (run with sudo)."
}

assert_file_exists() {
    local path="$1"
    [[ -f "$path" ]] || fail "Expected file not found: $path"
}

assert_contains_word() {
    local needle="$1"
    local haystack_file="$2"
    grep -Eq "(^|[^[:alnum:]_])${needle}([^[:alnum:]_]|$)" "$haystack_file" || \
        fail "Expected word '$needle' in $haystack_file"
}

resolve_latest_image() {
    local output_dir="$1"
    local latest

    latest=$(ls -1t "$output_dir"/*.img 2>/dev/null | head -n 1 || true)
    [[ -n "$latest" ]] || fail "No .img files found in $output_dir"
    echo "$latest"
}
