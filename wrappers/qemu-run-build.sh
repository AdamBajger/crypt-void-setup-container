#!/usr/bin/env bash
# qemu-run-build.sh — Execute the Void Linux FDE build inside a QEMU VM.
#
# The VM must already be set up via qemu-setup-vm.sh.  This script:
#   1. Starts the VM with 9p virtfs sharing the repository root.
#   2. Waits for SSH to become available.
#   3. Executes entrypoint.sh inside the VM with the required privileges.
#   4. Waits for the build to finish and shuts the VM down.
#   5. The completed .img is already in ./output/ via the shared folder.
#
# Required environment variables:
#   LUKS_PASSWORD, ROOT_PASSWORD, USER_PASSWORD
#
# Optional environment variables:
#   VOID_XBPS_REPOSITORY — defaults to https://repo-default.voidlinux.org/current
#   QEMU_VM_RAM          — VM memory in MiB (default: 4096)
#   QEMU_VM_CPUS         — VM CPU count (default: 2)
#   QEMU_VM_SSH_PORT     — Host port forwarded to VM port 22 (default: 2222)
#   QEMU_BUILD_TIMEOUT   — Max build time in seconds (default: 7200)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

log()  { echo "[qemu-run-build] $*"; }
die()  { echo "[qemu-run-build] ERROR: $*" >&2; exit 1; }
warn() { echo "[qemu-run-build] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VM_DIR="${REPO_ROOT}/vm"
VM_DISK="${VM_DIR}/void-builder.qcow2"
VM_PID_FILE="${VM_DIR}/vm.pid"

VM_RAM="${QEMU_VM_RAM:-4096}"
VM_CPUS="${QEMU_VM_CPUS:-2}"
VM_SSH_PORT="${QEMU_VM_SSH_PORT:-2222}"
BUILD_TIMEOUT="${QEMU_BUILD_TIMEOUT:-7200}"

SSH_KEY="${VM_DIR}/.ssh/vm_key"

VOID_XBPS_REPOSITORY="${VOID_XBPS_REPOSITORY:-https://repo-default.voidlinux.org/current}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found."
[[ -f "${VM_DISK}" ]] || die "VM disk not found at ${VM_DISK}. Run ./wrappers/qemu-setup-vm.sh first."
[[ -f "${SSH_KEY}" ]] || die "SSH key not found at ${SSH_KEY}. Run ./wrappers/qemu-setup-vm.sh first."

[[ -n "${LUKS_PASSWORD:-}" ]] || die "LUKS_PASSWORD is not set."
[[ -n "${ROOT_PASSWORD:-}" ]] || die "ROOT_PASSWORD is not set."
[[ -n "${USER_PASSWORD:-}" ]] || die "USER_PASSWORD is not set."

# ---------------------------------------------------------------------------
# SSH helper
# ---------------------------------------------------------------------------
vm_ssh() {
    ssh \
        -i "${SSH_KEY}" \
        -o "StrictHostKeyChecking=no" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "ConnectTimeout=5" \
        -p "${VM_SSH_PORT}" \
        root@127.0.0.1 \
        "$@"
}

# ---------------------------------------------------------------------------
# Cleanup handler — always shut down the VM on exit.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code="$?"
    log "Cleaning up VM..."
    vm_ssh poweroff 2>/dev/null || true

    if [[ -f "${VM_PID_FILE}" ]]; then
        VM_PID=$(cat "${VM_PID_FILE}" 2>/dev/null || true)
        if [[ -n "${VM_PID}" ]]; then
            WAIT=0
            while kill -0 "${VM_PID}" 2>/dev/null && [[ "${WAIT}" -lt 30 ]]; do
                sleep 2; WAIT=$((WAIT + 2))
            done
            kill "${VM_PID}" 2>/dev/null || true
        fi
        rm -f "${VM_PID_FILE}"
    fi

    if [[ "${exit_code}" -ne 0 ]]; then
        die "Build failed with exit code ${exit_code}. Check the output above for details."
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Start the VM with 9p virtfs sharing the repository root.
# ---------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/output"

log "Starting QEMU VM (RAM=${VM_RAM}MiB, CPUs=${VM_CPUS}, SSH port=${VM_SSH_PORT})..."
qemu-system-x86_64 \
    -m "${VM_RAM}" \
    -smp "${VM_CPUS}" \
    -enable-kvm \
    -machine accel=kvm:hvf:tcg \
    -drive "file=${VM_DISK},format=qcow2,if=virtio,cache=writeback" \
    -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -virtfs "local,path=${REPO_ROOT},mount_tag=host_share,security_model=mapped-xattr,id=host_share" \
    -nographic \
    -daemonize \
    -pidfile "${VM_PID_FILE}"

# ---------------------------------------------------------------------------
# Wait for SSH to become available.
# ---------------------------------------------------------------------------
log "Waiting for VM SSH on port ${VM_SSH_PORT} (up to 3 minutes)..."
TIMEOUT=180
ELAPSED=0
until vm_ssh true 2>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
        die "Timed out waiting for VM SSH. The VM may not have booted correctly."
    fi
done
log "VM is ready."

# ---------------------------------------------------------------------------
# Mount the shared repository folder inside the VM and run the build.
# ---------------------------------------------------------------------------
log "Mounting 9p shared folder inside VM..."
vm_ssh bash -s << 'MOUNT_CMDS'
set -euo pipefail
mkdir -p /mnt/host
if ! mountpoint -q /mnt/host; then
    mount -t 9p -o trans=virtio,version=9p2000.L host_share /mnt/host
fi
mkdir -p /mnt/host/output
MOUNT_CMDS

log "Executing build inside VM (timeout=${BUILD_TIMEOUT}s)..."
log "  Secrets are passed as environment variables over the encrypted SSH channel — not stored on disk."

# Run entrypoint.sh inside the VM with a timeout.
# Passwords are interpolated into the heredoc here on the local host and
# transmitted over the encrypted SSH channel via stdin — they are never
# written to disk and do not appear in any process listing.
vm_ssh bash -s << REMOTE_BUILD
set -euo pipefail

# Expose required kernel modules in the VM (Debian guest).
modprobe dm-mod   2>/dev/null || true
modprobe dm-crypt 2>/dev/null || true
modprobe loop     2>/dev/null || true

export LUKS_PASSWORD='${LUKS_PASSWORD}'
export ROOT_PASSWORD='${ROOT_PASSWORD}'
export USER_PASSWORD='${USER_PASSWORD}'
export VOID_XBPS_REPOSITORY='${VOID_XBPS_REPOSITORY}'

# Bind-mount the shared directories to the paths expected by entrypoint.sh.
mkdir -p /config /output /setup
mount --bind /mnt/host/config  /config  2>/dev/null || true
mount --bind /mnt/host/output  /output  2>/dev/null || true
mount --bind /mnt/host/scripts /setup   2>/dev/null || true

# Run the build with a timeout.
timeout ${BUILD_TIMEOUT} /setup/entrypoint.sh
EXIT_CODE=\$?

# Unmount bind mounts.
umount /config  2>/dev/null || true
umount /output  2>/dev/null || true
umount /setup   2>/dev/null || true

exit \${EXIT_CODE}
REMOTE_BUILD

log "Build completed successfully."
log "Check ${REPO_ROOT}/output/ for the disk image."
