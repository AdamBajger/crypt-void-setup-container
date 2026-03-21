#!/usr/bin/env bash
# Download the Void Linux live ISO for use with qemu-run-build.sh.
#
# Set VOID_ISO_URL to the ISO download URL before running.
# The ISO is saved to vm/void-live.iso.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
VM_DIR="${REPO_ROOT}/vm"
VOID_ISO="${VM_DIR}/void-live.iso"

mkdir -p "${VM_DIR}"

if [[ -f "${VOID_ISO}" ]]; then
    echo "${VOID_ISO} already exists."
    exit 0
fi

[[ -n "${VOID_ISO_URL:-}" ]] || {
    echo "ERROR: Set VOID_ISO_URL to the Void Linux live ISO download URL." >&2
    exit 1
}

echo "Downloading ${VOID_ISO_URL}..."
curl -L --progress-bar -o "${VOID_ISO}" "${VOID_ISO_URL}"
echo "Saved to ${VOID_ISO}."
