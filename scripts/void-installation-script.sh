#!/bin/bash
# void-installation-script.sh — Orchestrator for VoidLinux system configuration.
#
# This script runs INSIDE the xchroot environment set up by entrypoint.sh.
# It delegates work to two focused sub-scripts:
#
#   void-setup-minimal.sh — everything required for a bootable system
#                           (hostname, locale, fstab, crypttab, dracut,
#                            GRUB, users, runit services).
#   void-setup-extras.sh  — optional additional packages and customisation
#                           (none of which are critical for the OS to run).
#
# Both sub-scripts receive their configuration through the same environment
# variables that entrypoint.sh exported before calling xchroot:
#
#   VOID_HOSTNAME        — system hostname
#   VOID_USERNAME        — name of the regular user to create
#   VOID_TIMEZONE        — timezone (e.g. "Europe/Prague")
#   VOID_LOCALE          — locale  (e.g. "en_US.UTF-8")
#   VOID_KEYMAP          — keymap  (e.g. "us")
#   VOID_EFI_PARTITION   — block device path of the EFI partition
#   VOID_BOOT_PARTITION  — block device path of the boot partition
#   VOID_LUKS_PARTITION  — block device path of the LUKS partition
#   VOID_LUKS_DEVICE_NAME  — dm name for the opened LUKS container
#   VOID_LVM_VG_NAME       — LVM volume group name
#   VOID_LVM_ROOT_LV_NAME  — root logical volume name
#   VOID_LVM_SWAP_LV_NAME  — swap logical volume name
#   LUKS_PASSWORD        — LUKS passphrase
#   ROOT_PASSWORD        — password for the root account
#   USER_PASSWORD        — password for VOID_USERNAME

set -euo pipefail

log() { echo "[void-install] $*"; }

log "Starting minimal system setup..."
bash /tmp/void-setup-minimal.sh

log "Starting additional customisation..."
bash /tmp/void-setup-extras.sh

log "VoidLinux installation configuration complete."
