#!/bin/bash
# tools/qemu-verify-boot.sh - Boot the produced (encrypted) raw image headlessly
# under OVMF, supply the LUKS passphrase at the dracut prompt, and confirm it
# reaches a usable state. The decision is made by tools/qemu-verify.expect;
# this wrapper just sets it up and surfaces the serial log.
#
# Usage: qemu-verify-boot.sh <raw-disk> [logfile] [timeout-seconds] [luks-pass]
# Exit:  0 on success, non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISK="${1:-${REPO_ROOT}/output/void-vm.raw}"
LOGFILE="${2:-${REPO_ROOT}/logs/verify-boot.log}"
TIMEOUT="${3:-300}"
LUKS_PASS="${4:-ci-luks-password-not-secret}"

mkdir -p "$(dirname "${LOGFILE}")"

# shellcheck source=tools/qemu-vm-setup.sh
source "${REPO_ROOT}/tools/qemu-vm-setup.sh"

if [[ ! -f "${DISK}" ]]; then
    echo "[verify] ERROR: image not found: ${DISK}" >&2
    exit 1
fi

echo "[verify] Booting ${DISK} for up to ${TIMEOUT}s; serial log -> ${LOGFILE}"

set +e
run_verify_vm "${DISK}" "${LOGFILE}" "${TIMEOUT}" "${LUKS_PASS}"
rc=$?
set -e

echo "[verify] Last 40 lines of serial log:" >&2
tail -n 40 "${LOGFILE}" 2>/dev/null >&2 || true

if [[ ! -s "${LOGFILE}" ]]; then
    echo "[verify] FAIL: serial log is empty (VM produced no output)." >&2
    exit 2
fi

if [[ "${rc}" -eq 0 ]]; then
    echo "[verify] OK: image booted past LUKS decryption."
else
    echo "[verify] FAIL: verify VM did not reach the expected boot state (rc=${rc})." >&2
fi
exit "${rc}"
