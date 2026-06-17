#!/bin/bash
# build.sh — one-shot local build entry, run INSIDE a booted Void live VM.
#
# This repo is exposed to the VM as a read-only disk (QEMU vvfat, /dev/vdb1).
# After logging in (root / voidlinux), the ONLY thing you type is:
#
#     mkdir -p /repo && mount /dev/vdb1 /repo && bash /repo/build.sh
#
# (Not /mnt — the installer creates its target mount point at
# /mnt/void-install, which a read-only mount at /mnt would block.)
#
# Everything else — installer tools, networking, credentials (.env), disk and
# system config (config/*.conf), target device — is read from the files here.
# Nothing else to paste.
#
# It reuses the same scripts as every other path; only the device backend
# (raw, writing the produced image to /dev/vda) differs.

set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
log() { echo "[build] $*"; }

[[ $(id -u) -eq 0 ]] || { echo "[build] run as root" >&2; exit 1; }
[[ -f "${REPO}/tools/qemu-run-mounted.sh" ]] || { echo "[build] repo not found at ${REPO}" >&2; exit 1; }

# Bring networking up FIRST and wait for DNS. The live ISO's DHCP can lag a few
# seconds past login, and QEMU's user-mode (slirp) resolver occasionally throws
# a "Transient resolver failure" on the very first query — which would abort the
# xbps calls below under `set -e`. dhcpcd is idempotent if a service already ran.
if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -w -t 20 2>/dev/null || dhcpcd -t 20 2>/dev/null || true
fi
log "Waiting for repository DNS to resolve..."
for _ in $(seq 1 30); do
    getent hosts repo-default.voidlinux.org >/dev/null 2>&1 && break
    sleep 2
done

# Retry xbps on transient network/resolver hiccups instead of dying on the first.
xbps_retry() {
    local i
    for i in 1 2 3 4 5; do
        "$@" && return 0
        log "  (xbps attempt ${i} failed; retrying in 5s...)"
        sleep 5
    done
    return 1
}

# xbps must self-update before it installs anything on an older live ISO, then
# pull the installer tools the minimal "-base" image lacks.
log "Updating xbps + installing installer tools into the live environment..."
xbps_retry xbps-install -Suy xbps || log "WARNING: xbps self-update failed; continuing"
xbps_retry xbps-install -Sy parted cryptsetup lvm2 dosfstools e2fsprogs gptfdisk

# Hand off to the shared, config-driven installer (reads .env + config/ here,
# brings up networking, writes the image to /dev/vda).
log "Starting install..."
exec bash "${REPO}/tools/qemu-run-mounted.sh"
