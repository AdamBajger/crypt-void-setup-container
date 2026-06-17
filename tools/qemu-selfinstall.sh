#!/bin/bash
# tools/qemu-selfinstall.sh — run INSIDE a booted Void live VM to install Void
# onto the VM's disk using THIS repo, with no seed ISO, no expect, and no
# host-side tooling beyond QEMU itself.
#
# Intended for an interactive local run (e.g. QEMU on Windows): boot the Void
# live ISO, log in as root/voidlinux, then:
#
#   xbps-install -Suy xbps && xbps-install -Sy git \
#     && git clone -b qemu-pipeline-finish \
#          https://github.com/AdamBajger/crypt-void-setup-container.git /root/cvs \
#     && bash /root/cvs/tools/qemu-selfinstall.sh
#
# It reuses the exact same entrypoint.sh / install-core.sh / void-setup-*.sh as
# the Docker and CI paths — only the device backend (raw) differs.
#
# Override before running if you want non-default values, e.g.:
#   VOID_TARGET_DEVICE=/dev/vda LUKS_PASSWORD=... ROOT_PASSWORD=... \
#   USER_PASSWORD=... bash tools/qemu-selfinstall.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${VOID_TARGET_DEVICE:-/dev/vda}"

log() { echo "[selfinstall] $*"; }
die() { echo "[selfinstall] ERROR: $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || die "run as root (you are $(id -un))"
[[ -b "${TARGET}" ]] || die "target ${TARGET} is not a block device (set VOID_TARGET_DEVICE)"

# 1. xbps must self-update before it will install anything on an older live ISO.
log "Updating xbps..."
xbps-install -Suy xbps || log "WARNING: xbps self-update failed; continuing"

# 2. Tools the installer + the binary fetch need (absent from the -base ISO).
log "Installing host tools into the live environment..."
xbps-install -Sy parted cryptsetup lvm2 dosfstools e2fsprogs gptfdisk \
                 curl jq gnupg xz tar

# 3. Make sure networking is up (base-system + binaries come over the network).
if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -w -t 20 2>/dev/null || dhcpcd -t 20 2>/dev/null || true
fi
for _ in $(seq 1 15); do ip route 2>/dev/null | grep -q '^default' && break; sleep 1; done

# 4. Fetch the upstream binaries (Firefox / VS Code / ISO) straight into the VM.
log "Fetching upstream binaries..."
bash "${REPO_ROOT}/tools/fetch-binaries.sh"

# 5. Wire the in-VM paths entrypoint.sh expects to this checkout.
log "Wiring install paths..."
mkdir -p /config /setup /tools /binaries /output
mountpoint -q /setup    || mount --bind "${REPO_ROOT}/scripts"   /setup
mountpoint -q /tools    || mount --bind "${REPO_ROOT}/tools"     /tools
mountpoint -q /binaries || mount --bind "${REPO_ROOT}/binaries"  /binaries
cp -f "${REPO_ROOT}/config/disk.conf"          /config/disk.conf
cp -f "${REPO_ROOT}/config/system.conf"        /config/system.conf
cp -f "${REPO_ROOT}/config/extra-packages.txt" /config/extra-packages.txt

# 6. Backend + credentials. Override via the environment; these are defaults.
export VOID_DEVICE_BACKEND=raw
export VOID_TARGET_DEVICE="${TARGET}"
export LUKS_PASSWORD="${LUKS_PASSWORD:-voidlinux}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-voidlinux}"
export USER_PASSWORD="${USER_PASSWORD:-voidlinux}"

log "Installing Void onto ${TARGET} (LUKS passphrase: '${LUKS_PASSWORD}')..."
bash /setup/entrypoint.sh

log "DONE. Installed to ${TARGET}."
log "Power off (poweroff), detach the live ISO, and boot the disk."
