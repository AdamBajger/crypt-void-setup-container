#!/bin/bash
# void-bootstrap.sh — Install the base VoidLinux package set into the target
# filesystem.
#
# Called from entrypoint.sh (outside the chroot) after the target filesystem
# is mounted at VOID_INSTALL_MOUNT.
#
# Receives its configuration through environment variables exported by
# entrypoint.sh:
#
#   VOID_INSTALL_MOUNT   — mount-point of the target filesystem
#   VOID_XBPS_REPOSITORY — XBPS repository URL

set -euo pipefail

log() { echo "[void-bootstrap] $*"; }

log "Installing base packages into ${VOID_INSTALL_MOUNT}..."
log "  (Downloads from ${VOID_XBPS_REPOSITORY} — may take a while.)"

# Copy the container's xbps signing keys so that the target rootdir can
# verify repository signatures without prompting.
mkdir -p "${VOID_INSTALL_MOUNT}/var/db/xbps/keys"
cp /var/db/xbps/keys/* "${VOID_INSTALL_MOUNT}/var/db/xbps/keys/"

XBPS_ARCH=x86_64 xbps-install \
    -y \
    -i \
    -S \
    -r "${VOID_INSTALL_MOUNT}" \
    --repository="${VOID_XBPS_REPOSITORY}" \
    base-system \
    grub-x86_64-efi \
    efibootmgr \
    cryptsetup \
    lvm2 \
    dracut \
    dhcpcd \
    openssh

log "Base package installation complete."
