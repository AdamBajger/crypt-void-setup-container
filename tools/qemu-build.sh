#!/bin/bash
# tools/qemu-build.sh - Top-level orchestrator for the QEMU CI track.
#
# Steps:
#   1. Build the seed ISO from scripts/, config/, examples/, binaries/, tools/.
#   2. Allocate a 16 GiB raw disk image.
#   3. Boot the Void live kernel directly (serial console + autologin) with the
#      seed ISO attached; an expect script logs in, runs the installer against
#      /dev/vda, and waits for the VOID_INSTALL_RESULT sentinel (60 min budget).
#   4. Boot the produced image under OVMF, unlock LUKS, and verify it boots.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output"
LOG_DIR="${REPO_ROOT}/logs"
BIN_DIR="${REPO_ROOT}/binaries"
MANIFEST="${BIN_DIR}/manifest.json"

DISK_IMAGE="${OUTPUT_DIR}/void-vm.raw"
DISK_SIZE="${QEMU_DISK_SIZE:-16G}"
SEED_ISO="${OUTPUT_DIR}/seed.iso"
INSTALL_LOG="${LOG_DIR}/qemu-install.log"
INSTALL_TIMEOUT="${QEMU_INSTALL_TIMEOUT:-3600}"

# Throwaway, non-secret LUKS passphrase baked into the QEMU smoke-test image.
# The live VM does NOT inherit the host environment, so autorun.sh always falls
# back to this exact literal — keep the two in sync. The verify step needs it to
# unlock the volume. This is a disposable CI artifact, not a production system.
QEMU_CI_LUKS_PASSWORD="ci-luks-password-not-secret"

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

log() { echo "[qemu-build] $*"; }
die() { echo "[qemu-build] ERROR: $*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
command -v qemu-img             >/dev/null || die "qemu-img not installed"
command -v xorriso              >/dev/null || die "xorriso not installed"
command -v jq                   >/dev/null || die "jq not installed"
command -v expect               >/dev/null || die "expect not installed"

[[ -f "${MANIFEST}" ]] || die "manifest not found at ${MANIFEST} - run tools/fetch-binaries.sh first"

ISO_FILE=$(jq -r .void_iso.file "${MANIFEST}")
[[ -n "${ISO_FILE}" && "${ISO_FILE}" != "null" ]] || die "void_iso.file missing in manifest"
LIVE_ISO="${BIN_DIR}/void-iso/${ISO_FILE}"
[[ -f "${LIVE_ISO}" ]] || die "live ISO missing: ${LIVE_ISO}"

# ---------------------------------------------------------------------------
# Step 1: build seed ISO
# ---------------------------------------------------------------------------
log "Building seed ISO at ${SEED_ISO}..."
bash "${REPO_ROOT}/tools/qemu-seed-iso.sh" "${SEED_ISO}"

# ---------------------------------------------------------------------------
# Step 2: allocate raw disk
# ---------------------------------------------------------------------------
log "Allocating ${DISK_SIZE} raw disk at ${DISK_IMAGE}..."
rm -f "${DISK_IMAGE}"
qemu-img create -f raw "${DISK_IMAGE}" "${DISK_SIZE}"

# ---------------------------------------------------------------------------
# Step 3: install run
# ---------------------------------------------------------------------------
# The live VM boots its kernel directly with a serial console + autologin, and
# an expect script logs in, launches the seed autorun.sh, and watches the
# serial console for the VOID_INSTALL_RESULT sentinel. The whole session is
# mirrored to INSTALL_LOG (and to this job's stdout for live CI visibility).
# shellcheck source=tools/qemu-vm-setup.sh
source "${REPO_ROOT}/tools/qemu-vm-setup.sh"

log "Running install VM (expect-driven; up to ${INSTALL_TIMEOUT}s)..."
if run_install_vm "${DISK_IMAGE}" "${LIVE_ISO}" "${SEED_ISO}" "${INSTALL_LOG}" "${INSTALL_TIMEOUT}"; then
    log "Install signalled OK."
else
    die "Install failed or timed out. See ${INSTALL_LOG}."
fi

# The host-side raw file IS the produced artifact (VOID_DEVICE_BACKEND=raw
# inside the VM means the installer wrote directly to /dev/vda, which is
# this file). No extraction step is required.
log "produced: ${DISK_IMAGE}"

# ---------------------------------------------------------------------------
# Step 4: verify the produced image actually boots
# ---------------------------------------------------------------------------
log "Verifying produced image boots..."
bash "${REPO_ROOT}/tools/qemu-verify-boot.sh" "${DISK_IMAGE}" "${LOG_DIR}/qemu-verify.log" 300 "${QEMU_CI_LUKS_PASSWORD}"

log "Done. Image ready: ${DISK_IMAGE}"
