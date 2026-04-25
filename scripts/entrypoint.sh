#!/bin/bash
# entrypoint.sh - Thin orchestrator for the Void Linux FDE installer.
#
# Loads config, picks a device backend (loop file vs real block device),
# then runs the device-agnostic install sequence from install-core.sh.
# Cleanup tears down mounts/LVM/LUKS and asks the adapter to release/finalize.

set -euo pipefail

readonly DISK_CONFIG_FILE="/config/disk.conf"
readonly SYSTEM_CONFIG_FILE="/config/system.conf"
readonly SETUP_DIR="/setup"
readonly OUTPUT_DIR="/output"

readonly VOID_LUKS_DEVICE_NAME="void-luks"
readonly VOID_LVM_VG_NAME="void-vg"
readonly VOID_LVM_ROOT_LV_NAME="void-root"
readonly VOID_LVM_SWAP_LV_NAME="void-swap"
readonly VOID_INSTALL_MOUNT="/mnt/void-install"
readonly VOID_TARGET_ARCH="x86_64"
VOID_XBPS_REPOSITORY="${VOID_XBPS_REPOSITORY:-https://repo-default.voidlinux.org/current}"

VOID_EFI_PARTITION_INDEX=1
VOID_LUKS_PARTITION_INDEX=2
VOID_DEVICE=""
VOID_EFI_PARTITION=""
VOID_LUKS_PARTITION=""
VOID_DISK_IMAGE_PATH=""
VOID_OUTPUT_IMAGE_NAME=""
VOID_BUILD_TIMESTAMP=""
VOID_BUILD_COMPLETED=0
VOID_LAST_FILES_USED_HR=""
VOID_FINAL_IMAGE_NAME=""

log() { echo "[void-setup] $*"; }
die() { echo "[void-setup] ERROR: $*" >&2; exit 1; }

# shellcheck source=/setup/config-loader.sh
source "${SETUP_DIR}/config-loader.sh"
# shellcheck source=/setup/reporting.sh
source "${SETUP_DIR}/reporting.sh"
# shellcheck source=/setup/install-core.sh
source "${SETUP_DIR}/install-core.sh"

VOID_DEVICE_BACKEND="${VOID_DEVICE_BACKEND:-loop}"
case "${VOID_DEVICE_BACKEND}" in
    loop) source "${SETUP_DIR}/device-loop.sh" ;;
    raw)  source "${SETUP_DIR}/device-raw.sh" ;;
    *) die "VOID_DEVICE_BACKEND='${VOID_DEVICE_BACKEND}' is invalid (expected: loop|raw)" ;;
esac

cleanup() {
    local exit_status=$?
    teardown_target || true
    device_release || true
    device_finalize "$([[ ${exit_status} -eq 0 ]] && echo 1 || echo 0)" || true
    return ${exit_status}
}
trap cleanup EXIT

log "Validating environment variables..."
: "${LUKS_PASSWORD:?LUKS_PASSWORD is required but not set}"
: "${ROOT_PASSWORD:?ROOT_PASSWORD is required but not set}"
: "${USER_PASSWORD:?USER_PASSWORD is required but not set}"

log "Password variables before xchroot:"
log "  ROOT_PASSWORD length: ${#ROOT_PASSWORD}"
log "  USER_PASSWORD length: ${#USER_PASSWORD}"
log "  LUKS_PASSWORD length: ${#LUKS_PASSWORD}"

log "Running preflight verification for local binaries..."
bash /tools/preflight-verify-binaries.sh

log "Reading disk configuration from ${DISK_CONFIG_FILE}..."
load_config_file "${DISK_CONFIG_FILE}"
require_config_key "disk_size_mib"
require_config_key "efi_partition_size_mib"
require_config_key "swap_size_mib"
VOID_DISK_SIZE_MIB="${disk_size_mib}"
VOID_EFI_PARTITION_SIZE_MIB="${efi_partition_size_mib}"
VOID_SWAP_SIZE_MIB="${swap_size_mib}"

log "Reading system configuration from ${SYSTEM_CONFIG_FILE}..."
load_config_file "${SYSTEM_CONFIG_FILE}"
require_config_key "hostname"
require_config_key "username"
require_config_key "timezone"
require_config_key "locale"
require_config_key "keymap"
VOID_HOSTNAME="${hostname}"
VOID_USERNAME="${username}"
VOID_TIMEZONE="${timezone}"
VOID_LOCALE="${locale}"
VOID_KEYMAP="${keymap}"

log "==============================================================="
log " Void FDE installer  --  backend: ${VOID_DEVICE_BACKEND}"
log "==============================================================="
log "  disk_size_mib          = ${VOID_DISK_SIZE_MIB}"
log "  efi_partition_size_mib = ${VOID_EFI_PARTITION_SIZE_MIB}"
log "  swap_size_mib          = ${VOID_SWAP_SIZE_MIB}"
log "  hostname               = ${VOID_HOSTNAME}"
log "  username               = ${VOID_USERNAME}"
log "  timezone               = ${VOID_TIMEZONE}"
log "  locale                 = ${VOID_LOCALE}"
log "  keymap                 = ${VOID_KEYMAP}"

export VOID_INSTALL_MOUNT VOID_XBPS_REPOSITORY VOID_TARGET_ARCH
export VOID_HOSTNAME VOID_USERNAME VOID_TIMEZONE VOID_LOCALE VOID_KEYMAP
export VOID_LVM_VG_NAME VOID_LVM_ROOT_LV_NAME VOID_LVM_SWAP_LV_NAME
export VOID_LUKS_DEVICE_NAME
export ROOT_PASSWORD USER_PASSWORD LUKS_PASSWORD

device_acquire
partition_device "${VOID_DEVICE}"
device_resolve_partitions "${VOID_DEVICE}"
export VOID_EFI_PARTITION VOID_LUKS_PARTITION
setup_luks "${VOID_LUKS_PARTITION}"
setup_lvm
mkfs_filesystems "${VOID_EFI_PARTITION}"
mount_target "${VOID_EFI_PARTITION}"
install_base_system
report_phase_usage "base package installation"
copy_chroot_artifacts
run_minimal_setup
report_phase_usage "minimal system setup"
run_extras_setup
report_phase_usage "extra setup"

VOID_FINAL_IMAGE_NAME=$(build_final_image_name "${VOID_LAST_FILES_USED_HR}")
VOID_BUILD_COMPLETED=1

log "Final image name after cleanup will be ${VOID_FINAL_IMAGE_NAME}"
if [[ "${VOID_DEVICE_BACKEND}" == "loop" ]]; then
    log "Done. Flash ${VOID_FINAL_IMAGE_NAME} to a ${VOID_DISK_SIZE_MIB} MiB (or larger) device"
    log "using Balena Etcher or: sudo dd if=output/${VOID_FINAL_IMAGE_NAME} of=/dev/sdX bs=4M status=progress"
else
    log "Done. The host-side backing file for ${VOID_DEVICE} is the etchable artifact."
fi
