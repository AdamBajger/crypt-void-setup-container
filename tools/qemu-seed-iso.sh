#!/bin/bash
# tools/qemu-seed-iso.sh - Build the seed ISO consumed by the Void live VM.
#
# The seed ISO ships the project's scripts/, config/, examples/, binaries/
# and tools/ trees plus a top-level autorun.sh that runs the installer
# against /dev/vda and signals completion via virtio-serial.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ISO="${1:-${REPO_ROOT}/output/seed.iso}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[seed-iso] ERROR: missing $1" >&2; exit 1; }; }
need xorriso
need jq

mkdir -p "$(dirname "${OUTPUT_ISO}")"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

echo "[seed-iso] Staging payload at ${STAGE_DIR}..."

# Bundle the entire project tree the installer expects to see at /root/install/.
cp -a "${REPO_ROOT}/scripts"  "${STAGE_DIR}/scripts"
cp -a "${REPO_ROOT}/config"   "${STAGE_DIR}/config"
cp -a "${REPO_ROOT}/examples" "${STAGE_DIR}/examples"
cp -a "${REPO_ROOT}/tools"    "${STAGE_DIR}/tools"
cp -a "${REPO_ROOT}/binaries" "${STAGE_DIR}/binaries"

# Top-level autorun.sh — runs inside the Void live ISO as root.
cat >"${STAGE_DIR}/autorun.sh" <<'AUTORUN_EOF'
#!/bin/bash
# autorun.sh - Entry point executed by the Void live VM after boot.
#
# Reports completion to the host over virtio-serial, then powers off.

set -uo pipefail

SEED_MOUNT="/mnt/seed"
INSTALL_ROOT="/root/install"
SIGNAL_PORT="/dev/virtio-ports/qemu-install-status"

log() { echo "[autorun] $*"; }

signal_host() {
    local payload="$1"
    if [[ -e "${SIGNAL_PORT}" ]]; then
        printf '%s\n' "${payload}" > "${SIGNAL_PORT}" 2>/dev/null || true
    fi
    # Fallback: write to every vport node we can find so the host always sees it.
    for p in /dev/vport*; do
        [[ -e "${p}" ]] || continue
        printf '%s\n' "${payload}" > "${p}" 2>/dev/null || true
    done
    sync || true
}

finish() {
    local status="$1"
    if [[ "${status}" -eq 0 ]]; then
        log "Install succeeded; signalling host."
        signal_host "INSTALL_OK"
    else
        log "Install failed (status ${status}); signalling host."
        signal_host "INSTALL_FAIL"
    fi
    sleep 2
    poweroff -f || /sbin/poweroff -f || halt -f
}

mkdir -p "${SEED_MOUNT}"
if ! mountpoint -q "${SEED_MOUNT}"; then
    SEED_DEV=""
    for cand in /dev/sr1 /dev/sr0 /dev/vdb /dev/vdc; do
        [[ -b "${cand}" ]] || continue
        if blkid -o value -s LABEL "${cand}" 2>/dev/null | grep -qx "VOIDSEED"; then
            SEED_DEV="${cand}"; break
        fi
    done
    if [[ -z "${SEED_DEV}" ]]; then
        for cand in /dev/sr1 /dev/sr0 /dev/vdb /dev/vdc; do
            [[ -b "${cand}" ]] && SEED_DEV="${cand}" && break
        done
    fi
    if [[ -z "${SEED_DEV}" ]]; then
        log "Could not locate seed media."
        finish 1
    fi
    log "Mounting seed device ${SEED_DEV} at ${SEED_MOUNT}..."
    mount -o ro "${SEED_DEV}" "${SEED_MOUNT}" || { log "mount failed"; finish 1; }
fi

mkdir -p "${INSTALL_ROOT}"
log "Copying seed payload to ${INSTALL_ROOT}..."
cp -a "${SEED_MOUNT}/." "${INSTALL_ROOT}/" || { log "copy failed"; finish 1; }

chmod +x "${INSTALL_ROOT}/scripts"/*.sh 2>/dev/null || true
chmod +x "${INSTALL_ROOT}/tools"/*.sh   2>/dev/null || true

# Map the in-VM paths the entrypoint script expects (/setup, /tools,
# /binaries, /output) to the unpacked install tree. /config is populated
# explicitly below so the QEMU-targeted overrides are unambiguous.
mkdir -p /config /setup /tools /binaries /output
mount --bind "${INSTALL_ROOT}/scripts"  /setup
mount --bind "${INSTALL_ROOT}/tools"    /tools
mount --bind "${INSTALL_ROOT}/binaries" /binaries

if [[ -f "${INSTALL_ROOT}/examples/qemu-vm.conf" ]]; then
    cp -f "${INSTALL_ROOT}/examples/qemu-vm.conf" /config/disk.conf
else
    cp -f "${INSTALL_ROOT}/config/disk.conf"      /config/disk.conf
fi
cp -f "${INSTALL_ROOT}/config/system.conf"        /config/system.conf
cp -f "${INSTALL_ROOT}/config/extra-packages.txt" /config/extra-packages.txt

export VOID_DEVICE_BACKEND=raw
export VOID_TARGET_DEVICE=/dev/vda
export LUKS_PASSWORD="${LUKS_PASSWORD:-ci-luks-password-not-secret}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-ci-root-password-not-secret}"
export USER_PASSWORD="${USER_PASSWORD:-ci-user-password-not-secret}"

log "Running entrypoint.sh against ${VOID_TARGET_DEVICE}..."
if bash /setup/entrypoint.sh; then
    finish 0
else
    finish $?
fi
AUTORUN_EOF
chmod +x "${STAGE_DIR}/autorun.sh"

echo "[seed-iso] Building ISO at ${OUTPUT_ISO}..."
xorriso -as mkisofs \
    -volid VOIDSEED \
    -joliet \
    -rational-rock \
    -o "${OUTPUT_ISO}" \
    "${STAGE_DIR}"

echo "[seed-iso] Done: ${OUTPUT_ISO}"
ls -lh "${OUTPUT_ISO}"
