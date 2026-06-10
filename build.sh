#!/bin/bash
# build.sh — one-shot local build entry, run INSIDE a booted Void live VM.
#
# This repo is exposed to the VM as a read-only disk (QEMU vvfat, /dev/vdb).
# After logging in (root / voidlinux), the ONLY thing you type is:
#
#     mount /dev/vdb /mnt && bash /mnt/build.sh
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

# xbps must self-update before it installs anything on an older live ISO, then
# pull the installer tools the minimal "-base" image lacks.
log "Updating xbps + installing installer tools into the live environment..."
xbps-install -Suy xbps || log "WARNING: xbps self-update failed; continuing"
xbps-install -Sy parted cryptsetup lvm2 dosfstools e2fsprogs gptfdisk

# Hand off to the shared, config-driven installer (reads .env + config/ here,
# brings up networking, writes the image to /dev/vda).
log "Starting install..."
exec bash "${REPO}/tools/qemu-run-mounted.sh"
