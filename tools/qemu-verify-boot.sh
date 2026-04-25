#!/bin/bash
# tools/qemu-verify-boot.sh - Boot the produced raw image headlessly and
# confirm we reach a usable state (login prompt, KDE startup, or SDDM).
#
# Usage: qemu-verify-boot.sh <raw-disk> [logfile] [timeout-seconds]
# Exit:  0 on success, non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISK="${1:-${REPO_ROOT}/output/void-vm.raw}"
LOGFILE="${2:-${REPO_ROOT}/logs/verify-boot.log}"
TIMEOUT="${3:-180}"

mkdir -p "$(dirname "${LOGFILE}")"

# shellcheck source=tools/qemu-vm-setup.sh
source "${REPO_ROOT}/tools/qemu-vm-setup.sh"

if [[ ! -f "${DISK}" ]]; then
    echo "[verify] ERROR: image not found: ${DISK}" >&2
    exit 1
fi

echo "[verify] Booting ${DISK} for up to ${TIMEOUT}s; serial log -> ${LOGFILE}"

# run_verify_vm always returns 0 (timeout is the expected stop condition);
# success is decided by scraping the serial log for known boot tokens.
run_verify_vm "${DISK}" "${LOGFILE}" "${TIMEOUT}"

# Tokens that indicate the image successfully reached a real userspace.
PATTERNS=(
    'sddm'
    'SDDM'
    'login:'
    'Welcome to Void'
    'startkde'
    'plasmashell'
    'KDE Plasma'
    'systemd-logind'
    'runit: enter stage'
)

if [[ ! -s "${LOGFILE}" ]]; then
    echo "[verify] FAIL: serial log is empty (VM produced no output)." >&2
    exit 2
fi

echo "[verify] Last 40 lines of serial log:" >&2
tail -n 40 "${LOGFILE}" >&2 || true

for pat in "${PATTERNS[@]}"; do
    if grep -qE "${pat}" "${LOGFILE}"; then
        echo "[verify] OK: matched '${pat}' in serial log."
        exit 0
    fi
done

echo "[verify] FAIL: none of the success tokens appeared in ${LOGFILE}" >&2
exit 3
