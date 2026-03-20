#!/usr/bin/env bash
# run-build.sh — Main entry point for the Void Linux FDE build.
#
# Usage:
#   ./wrappers/run-build.sh [docker|qemu|auto]
#
# Modes:
#   docker  — Run the build inside a privileged Docker container.
#   qemu    — Run the build inside a QEMU virtual machine.
#   auto    — (default) Auto-detect the best available method.
#
# Environment variables consumed by this script:
#   LUKS_PASSWORD   — required
#   ROOT_PASSWORD   — required
#   USER_PASSWORD   — required
#   VOID_XBPS_REPOSITORY — optional, defaults to https://repo-default.voidlinux.org/current

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

log()  { echo "[run-build] $*"; }
die()  { echo "[run-build] ERROR: $*" >&2; exit 1; }
warn() { echo "[run-build] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Validate required secrets before going any further.
# ---------------------------------------------------------------------------
validate_passwords() {
    [[ -n "${LUKS_PASSWORD:-}" ]] || die "LUKS_PASSWORD is not set. Export it before running this script."
    [[ -n "${ROOT_PASSWORD:-}" ]] || die "ROOT_PASSWORD is not set. Export it before running this script."
    [[ -n "${USER_PASSWORD:-}" ]] || die "USER_PASSWORD is not set. Export it before running this script."
}

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------
docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

qemu_available() {
    command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1
}

qemu_vm_configured() {
    [[ -f "${REPO_ROOT}/vm/void-builder.qcow2" ]]
}

# ---------------------------------------------------------------------------
# Build method implementations
# ---------------------------------------------------------------------------
run_docker() {
    log "Using Docker (privileged) build method."
    "${SCRIPT_DIR}/run-docker-privileged.sh"
}

run_qemu() {
    log "Using QEMU VM build method."
    if ! qemu_vm_configured; then
        die "QEMU VM disk not found at vm/void-builder.qcow2." \
            "Run ./wrappers/qemu-setup-vm.sh first to create the VM."
    fi
    "${SCRIPT_DIR}/qemu-run-build.sh"
}

# ---------------------------------------------------------------------------
# Auto-detection logic
# ---------------------------------------------------------------------------
auto_detect() {
    log "Auto-detecting best available build method..."

    if docker_available; then
        log "  Docker is available → using Docker."
        run_docker
        return
    fi

    if qemu_available && qemu_vm_configured; then
        log "  QEMU is available and VM is configured → using QEMU."
        run_qemu
        return
    fi

    die "No suitable build method found.
  - Install Docker (https://docs.docker.com/get-docker/) for the Docker method.
  - Install QEMU and run ./wrappers/qemu-setup-vm.sh for the QEMU method."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MODE="${1:-auto}"

validate_passwords

case "${MODE}" in
    docker) run_docker ;;
    qemu)   run_qemu ;;
    auto)   auto_detect ;;
    *)
        echo "Usage: $(basename "$0") [docker|qemu|auto]" >&2
        exit 1
        ;;
esac
