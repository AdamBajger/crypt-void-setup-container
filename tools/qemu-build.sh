#!/bin/bash
# tools/qemu-build.sh - Top-level orchestrator for the QEMU CI track.
#
# Steps:
#   1. Build the seed ISO from scripts/, config/, examples/, binaries/, tools/.
#   2. Allocate a 16 GiB raw disk image.
#   3. Boot the Void live ISO + seed ISO in QEMU; wait for INSTALL_OK over
#      a virtio-serial unix socket (60 min budget).
#   4. Boot the produced image headlessly and verify it reaches userspace.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output"
LOG_DIR="${REPO_ROOT}/logs"
BIN_DIR="${REPO_ROOT}/binaries"
MANIFEST="${BIN_DIR}/manifest.json"

DISK_IMAGE="${OUTPUT_DIR}/void-vm.raw"
DISK_SIZE="${QEMU_DISK_SIZE:-16G}"
SEED_ISO="${OUTPUT_DIR}/seed.iso"
SIGNAL_SOCK="${OUTPUT_DIR}/qemu-status.sock"
INSTALL_LOG="${LOG_DIR}/qemu-install.log"
INSTALL_TIMEOUT="${QEMU_INSTALL_TIMEOUT:-3600}"

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

log() { echo "[qemu-build] $*"; }
die() { echo "[qemu-build] ERROR: $*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
command -v qemu-img             >/dev/null || die "qemu-img not installed"
command -v xorriso              >/dev/null || die "xorriso not installed"
command -v jq                   >/dev/null || die "jq not installed"
command -v socat                >/dev/null || die "socat not installed"

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
# shellcheck source=tools/qemu-vm-setup.sh
source "${REPO_ROOT}/tools/qemu-vm-setup.sh"

STATUS_FILE="${OUTPUT_DIR}/install-status.txt"
rm -f "${STATUS_FILE}" "${SIGNAL_SOCK}"

cleanup() {
    [[ -n "${TAIL_PID:-}"  ]] && kill "${TAIL_PID}"  2>/dev/null || true
    [[ -n "${SOCAT_PID:-}" ]] && kill "${SOCAT_PID}" 2>/dev/null || true
    [[ -n "${QEMU_PID:-}"  ]] && { kill "${QEMU_PID}" 2>/dev/null || true; sleep 1; kill -KILL "${QEMU_PID}" 2>/dev/null || true; }
    rm -f "${SIGNAL_SOCK}"
}
trap cleanup EXIT

log "Starting socat listener on ${SIGNAL_SOCK} -> ${STATUS_FILE}..."
( run_install_vm "${DISK_IMAGE}" "${LIVE_ISO}" "${SEED_ISO}" "${SIGNAL_SOCK}" "${INSTALL_LOG}" ) &
QEMU_PID=$!

# Wait for QEMU to create the unix socket before connecting socat.
for _ in $(seq 1 60); do
    [[ -S "${SIGNAL_SOCK}" ]] && break
    sleep 1
done
[[ -S "${SIGNAL_SOCK}" ]] || die "QEMU did not create signal socket ${SIGNAL_SOCK}"

socat -u "UNIX-CONNECT:${SIGNAL_SOCK}" "OPEN:${STATUS_FILE},creat,append" &
SOCAT_PID=$!

# Stream the in-VM serial console live so progress is visible in CI output.
touch "${INSTALL_LOG}"
( tail -n +1 -F "${INSTALL_LOG}" 2>/dev/null | sed 's/^/[guest] /' ) &
TAIL_PID=$!

log "Waiting up to ${INSTALL_TIMEOUT}s for INSTALL_OK / INSTALL_FAIL..."
start_ts=$(date +%s)
deadline=$(( start_ts + INSTALL_TIMEOUT ))
last_heartbeat=${start_ts}
result=""
while (( $(date +%s) < deadline )); do
    if [[ -s "${STATUS_FILE}" ]]; then
        if grep -q INSTALL_OK   "${STATUS_FILE}"; then result="OK";   break; fi
        if grep -q INSTALL_FAIL "${STATUS_FILE}"; then result="FAIL"; break; fi
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        log "QEMU exited; checking final status..."
        sleep 2
        if [[ -s "${STATUS_FILE}" ]]; then
            grep -q INSTALL_OK   "${STATUS_FILE}" && result="OK"
            grep -q INSTALL_FAIL "${STATUS_FILE}" && result="FAIL"
        fi
        break
    fi
    now=$(date +%s)
    if (( now - last_heartbeat >= 300 )); then
        log "still waiting ($((now - start_ts))s elapsed of ${INSTALL_TIMEOUT}s budget)..."
        last_heartbeat=${now}
    fi
    sleep 5
done

# Give QEMU up to 30s to power off cleanly (autorun calls poweroff after
# signaling); SIGKILL after that so we never block on a stuck guest.
for _ in $(seq 1 30); do
    kill -0 "${QEMU_PID}" 2>/dev/null || break
    sleep 1
done
kill -TERM "${QEMU_PID}" 2>/dev/null || true
sleep 2
kill -KILL "${QEMU_PID}" 2>/dev/null || true
wait "${QEMU_PID}" 2>/dev/null || true
QEMU_PID=""
kill "${SOCAT_PID}" 2>/dev/null || true
SOCAT_PID=""
kill "${TAIL_PID}"  2>/dev/null || true
TAIL_PID=""

case "${result}" in
    OK)   log "Install signalled OK." ;;
    FAIL) die "Install signalled FAIL. See ${INSTALL_LOG} and ${STATUS_FILE}." ;;
    *)    die "Install timed out after ${INSTALL_TIMEOUT}s. See ${INSTALL_LOG}." ;;
esac

# The host-side raw file IS the produced artifact (VOID_DEVICE_BACKEND=raw
# inside the VM means the installer wrote directly to /dev/vda, which is
# this file). No extraction step is required.
log "produced: ${DISK_IMAGE}"

# ---------------------------------------------------------------------------
# Step 4: verify the produced image actually boots
# ---------------------------------------------------------------------------
log "Verifying produced image boots..."
bash "${REPO_ROOT}/tools/qemu-verify-boot.sh" "${DISK_IMAGE}" "${LOG_DIR}/qemu-verify.log" 180

log "Done. Image ready: ${DISK_IMAGE}"
