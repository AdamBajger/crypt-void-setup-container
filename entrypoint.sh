#!/bin/bash
# entrypoint.sh — Main orchestration script for the crypt-void-setup-container.
#
# This script runs inside the VoidLinux Docker container and performs the full
# pipeline:
#   1. Parse YAML configuration files.
#   2. Create a loopback disk image sized to match the target device.
#   3. Partition the image (GPT: EFI + unencrypted boot + LUKS).
#   4. Set up LUKS1 encryption with PBKDF2 on the third partition.
#   5. Set up LVM (volume group + logical volumes) inside the LUKS container.
#   6. Format all filesystems (FAT32 / ext4 / swap).
#   7. Mount the filesystem tree.
#   8. Bootstrap a minimal VoidLinux installation into the mounted tree.
#   9. Run void-installation-script.sh inside xchroot to configure the system.
#  10. Unmount, close LUKS, detach loop device.
#  11. Save the raw disk image to the output directory.

set -euo pipefail

# ---------------------------------------------------------------------------
# Hard-coded names — kept verbose and consistent for maximum readability.
# ---------------------------------------------------------------------------
readonly DISK_CONFIG_FILE="/config/disk.yaml"
readonly SYSTEM_CONFIG_FILE="/config/system.yaml"
readonly OUTPUT_DIR="/output"

readonly VOID_DISK_IMAGE_PATH="/tmp/void-disk.img"

readonly VOID_LUKS_DEVICE_NAME="void-luks"
readonly VOID_LUKS_DEVICE_PATH="/dev/mapper/${VOID_LUKS_DEVICE_NAME}"

readonly VOID_LVM_VG_NAME="void-vg"
readonly VOID_LVM_ROOT_LV_NAME="void-root"
readonly VOID_LVM_SWAP_LV_NAME="void-swap"

readonly VOID_INSTALL_MOUNT="/mnt/void-install"

readonly VOID_XBPS_REPOSITORY="https://repo-default.voidlinux.org/current"

# Partition indices within the loop device.
readonly VOID_EFI_PARTITION_INDEX=1
readonly VOID_BOOT_PARTITION_INDEX=2
readonly VOID_LUKS_PARTITION_INDEX=3

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[void-setup] $*"; }
die() { echo "[void-setup] ERROR: $*" >&2; exit 1; }

get_yaml_value() {
    local yaml_file="$1"
    local key="$2"
    python3 - "$yaml_file" "$key" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
value = data.get(sys.argv[2], "")
if value == "" or value is None:
    sys.exit(f"Key '{sys.argv[2]}' not found or empty in {sys.argv[1]}")
print(value)
PYEOF
}

# ---------------------------------------------------------------------------
# Step 0 — Validate required environment variables.
# ---------------------------------------------------------------------------
log "Validating environment variables..."
: "${LUKS_PASSWORD:?LUKS_PASSWORD is required but not set}"
: "${ROOT_PASSWORD:?ROOT_PASSWORD is required but not set}"
: "${USER_PASSWORD:?USER_PASSWORD is required but not set}"

# ---------------------------------------------------------------------------
# Step 1 — Parse YAML configuration.
# ---------------------------------------------------------------------------
log "Reading disk configuration from ${DISK_CONFIG_FILE}..."
VOID_DISK_SIZE_MB=$(get_yaml_value "${DISK_CONFIG_FILE}" "disk_size_mb")
VOID_EFI_PARTITION_SIZE_MB=$(get_yaml_value "${DISK_CONFIG_FILE}" "efi_partition_size_mb")
VOID_BOOT_PARTITION_SIZE_MB=$(get_yaml_value "${DISK_CONFIG_FILE}" "boot_partition_size_mb")
VOID_SWAP_SIZE_MB=$(get_yaml_value "${DISK_CONFIG_FILE}" "swap_size_mb")

log "Reading system configuration from ${SYSTEM_CONFIG_FILE}..."
VOID_HOSTNAME=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "hostname")
VOID_USERNAME=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "username")
VOID_TIMEZONE=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "timezone")
VOID_LOCALE=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "locale")
VOID_KEYMAP=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "keymap")

log "  disk_size_mb          = ${VOID_DISK_SIZE_MB}"
log "  efi_partition_size_mb = ${VOID_EFI_PARTITION_SIZE_MB}"
log "  boot_partition_size_mb= ${VOID_BOOT_PARTITION_SIZE_MB}"
log "  swap_size_mb          = ${VOID_SWAP_SIZE_MB}"
log "  hostname              = ${VOID_HOSTNAME}"
log "  username              = ${VOID_USERNAME}"
log "  timezone              = ${VOID_TIMEZONE}"
log "  locale                = ${VOID_LOCALE}"
log "  keymap                = ${VOID_KEYMAP}"

# ---------------------------------------------------------------------------
# Step 2 — Create the loopback disk image.
# ---------------------------------------------------------------------------
log "Creating ${VOID_DISK_SIZE_MB} MiB disk image at ${VOID_DISK_IMAGE_PATH}..."
truncate -s "${VOID_DISK_SIZE_MB}M" "${VOID_DISK_IMAGE_PATH}"

log "Attaching disk image to a loop device..."
VOID_LOOP_DEVICE=$(losetup --find --show --partscan "${VOID_DISK_IMAGE_PATH}")
readonly VOID_LOOP_DEVICE
log "  loop device = ${VOID_LOOP_DEVICE}"

VOID_EFI_PARTITION="${VOID_LOOP_DEVICE}p${VOID_EFI_PARTITION_INDEX}"
VOID_BOOT_PARTITION="${VOID_LOOP_DEVICE}p${VOID_BOOT_PARTITION_INDEX}"
VOID_LUKS_PARTITION="${VOID_LOOP_DEVICE}p${VOID_LUKS_PARTITION_INDEX}"

# ---------------------------------------------------------------------------
# Cleanup trap — executed on exit to ensure all resources are released even
# if the script fails partway through.
# ---------------------------------------------------------------------------
cleanup() {
    log "Running cleanup..."
    # Unmount in reverse order.
    umount "${VOID_INSTALL_MOUNT}/boot/efi" 2>/dev/null || true
    umount "${VOID_INSTALL_MOUNT}/boot"     2>/dev/null || true
    umount "${VOID_INSTALL_MOUNT}"          2>/dev/null || true
    # Deactivate LVM.
    vgchange -an "${VOID_LVM_VG_NAME}" 2>/dev/null || true
    # Close LUKS.
    cryptsetup close "${VOID_LUKS_DEVICE_NAME}" 2>/dev/null || true
    # Detach loop device.
    losetup -d "${VOID_LOOP_DEVICE}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 3 — Partition the disk image (GPT layout targeting EFI systems).
# ---------------------------------------------------------------------------
log "Partitioning disk image with GPT layout..."

# All start/end positions are in MiB to ensure proper alignment.
VOID_EFI_PART_START=1
VOID_EFI_PART_END=$((VOID_EFI_PART_START + VOID_EFI_PARTITION_SIZE_MB))
VOID_BOOT_PART_START=${VOID_EFI_PART_END}
VOID_BOOT_PART_END=$((VOID_BOOT_PART_START + VOID_BOOT_PARTITION_SIZE_MB))
VOID_LUKS_PART_START=${VOID_BOOT_PART_END}

parted --script "${VOID_LOOP_DEVICE}" \
    mklabel gpt \
    mkpart void-efi-partition  fat32 "${VOID_EFI_PART_START}MiB"  "${VOID_EFI_PART_END}MiB" \
    mkpart void-boot-partition ext4  "${VOID_BOOT_PART_START}MiB" "${VOID_BOOT_PART_END}MiB" \
    mkpart void-luks-partition       "${VOID_LUKS_PART_START}MiB" "100%" \
    set "${VOID_EFI_PARTITION_INDEX}" esp on

# Re-read the partition table so that the kernel picks up the new partitions.
partprobe "${VOID_LOOP_DEVICE}"
sleep 1

log "  ${VOID_EFI_PARTITION}  — EFI System Partition (FAT32)"
log "  ${VOID_BOOT_PARTITION} — unencrypted boot partition (ext4)"
log "  ${VOID_LUKS_PARTITION} — LUKS1 encrypted partition (contains LVM)"

# ---------------------------------------------------------------------------
# Step 4 — Set up LUKS1 encryption with PBKDF2 on the third partition.
# ---------------------------------------------------------------------------
log "Formatting ${VOID_LUKS_PARTITION} as LUKS1 with PBKDF2..."
echo -n "${LUKS_PASSWORD}" | cryptsetup luksFormat \
    --type luks1 \
    --pbkdf pbkdf2 \
    --batch-mode \
    "${VOID_LUKS_PARTITION}" -

log "Opening LUKS container as ${VOID_LUKS_DEVICE_NAME}..."
echo -n "${LUKS_PASSWORD}" | cryptsetup open \
    "${VOID_LUKS_PARTITION}" "${VOID_LUKS_DEVICE_NAME}" -

# ---------------------------------------------------------------------------
# Step 5 — Set up LVM inside the LUKS container.
# ---------------------------------------------------------------------------
log "Initialising LVM physical volume on ${VOID_LUKS_DEVICE_PATH}..."
pvcreate "${VOID_LUKS_DEVICE_PATH}"

log "Creating volume group ${VOID_LVM_VG_NAME}..."
vgcreate "${VOID_LVM_VG_NAME}" "${VOID_LUKS_DEVICE_PATH}"

log "Creating swap logical volume (${VOID_SWAP_SIZE_MB} MiB)..."
lvcreate -L "${VOID_SWAP_SIZE_MB}M" -n "${VOID_LVM_SWAP_LV_NAME}" "${VOID_LVM_VG_NAME}"

log "Creating root logical volume (remaining space)..."
lvcreate -l 100%FREE -n "${VOID_LVM_ROOT_LV_NAME}" "${VOID_LVM_VG_NAME}"

# ---------------------------------------------------------------------------
# Step 6 — Format all filesystems.
# ---------------------------------------------------------------------------
log "Formatting EFI partition as FAT32..."
mkfs.vfat -F32 -n VOID-EFI "${VOID_EFI_PARTITION}"

log "Formatting boot partition as ext4..."
mkfs.ext4 -L void-boot "${VOID_BOOT_PARTITION}"

log "Formatting root logical volume as ext4..."
mkfs.ext4 -L void-root "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}"

log "Setting up swap on swap logical volume..."
mkswap -L void-swap "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_SWAP_LV_NAME}"

# ---------------------------------------------------------------------------
# Step 7 — Mount the filesystem tree.
# ---------------------------------------------------------------------------
log "Mounting root filesystem at ${VOID_INSTALL_MOUNT}..."
mkdir -p "${VOID_INSTALL_MOUNT}"
mount "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}" "${VOID_INSTALL_MOUNT}"

log "Mounting boot partition at ${VOID_INSTALL_MOUNT}/boot..."
mkdir -p "${VOID_INSTALL_MOUNT}/boot"
mount "${VOID_BOOT_PARTITION}" "${VOID_INSTALL_MOUNT}/boot"

log "Mounting EFI partition at ${VOID_INSTALL_MOUNT}/boot/efi..."
mkdir -p "${VOID_INSTALL_MOUNT}/boot/efi"
mount "${VOID_EFI_PARTITION}" "${VOID_INSTALL_MOUNT}/boot/efi"

# ---------------------------------------------------------------------------
# Step 8 — Bootstrap a minimal VoidLinux installation.
# ---------------------------------------------------------------------------
log "Bootstrapping VoidLinux base system into ${VOID_INSTALL_MOUNT}..."
log "  (This downloads packages from ${VOID_XBPS_REPOSITORY} — may take a while.)"

XBPS_ARCH=x86_64 xbps-install \
    -y \
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

# ---------------------------------------------------------------------------
# Step 9 — Configure the system inside xchroot.
# ---------------------------------------------------------------------------
log "Copying void-installation-script.sh into chroot..."
cp /setup/void-installation-script.sh "${VOID_INSTALL_MOUNT}/tmp/void-installation-script.sh"
chmod +x "${VOID_INSTALL_MOUNT}/tmp/void-installation-script.sh"

log "Running void-installation-script.sh inside xchroot..."
# All VOID_* and password variables are exported so that the installation
# script can read them from its environment without any additional argument
# passing.
export VOID_HOSTNAME VOID_USERNAME VOID_TIMEZONE VOID_LOCALE VOID_KEYMAP
export VOID_EFI_PARTITION VOID_BOOT_PARTITION VOID_LUKS_PARTITION
export VOID_LUKS_DEVICE_NAME VOID_LVM_VG_NAME
export VOID_LVM_ROOT_LV_NAME VOID_LVM_SWAP_LV_NAME
export ROOT_PASSWORD USER_PASSWORD LUKS_PASSWORD

xchroot "${VOID_INSTALL_MOUNT}" /tmp/void-installation-script.sh

# ---------------------------------------------------------------------------
# Step 10 — Unmount, close LUKS, detach loop device.
#           (The cleanup trap handles this automatically on EXIT.)
# ---------------------------------------------------------------------------
log "Unmounting filesystems..."
umount "${VOID_INSTALL_MOUNT}/boot/efi"
umount "${VOID_INSTALL_MOUNT}/boot"
umount "${VOID_INSTALL_MOUNT}"

log "Deactivating LVM volume group..."
vgchange -an "${VOID_LVM_VG_NAME}"

log "Closing LUKS container..."
cryptsetup close "${VOID_LUKS_DEVICE_NAME}"

log "Detaching loop device ${VOID_LOOP_DEVICE}..."
losetup -d "${VOID_LOOP_DEVICE}"

# Disable the cleanup trap — we have already cleaned up manually.
trap - EXIT

# ---------------------------------------------------------------------------
# Step 11 — Save the raw disk image to the output directory.
# ---------------------------------------------------------------------------
VOID_OUTPUT_IMAGE_NAME="void-linux-encrypted-$(date +%Y%m%d-%H%M%S).img"
VOID_OUTPUT_IMAGE_PATH="${OUTPUT_DIR}/${VOID_OUTPUT_IMAGE_NAME}"

log "Saving disk image to ${VOID_OUTPUT_IMAGE_PATH}..."
cp "${VOID_DISK_IMAGE_PATH}" "${VOID_OUTPUT_IMAGE_PATH}"
rm -f "${VOID_DISK_IMAGE_PATH}"

log "Done.  Flash ${VOID_OUTPUT_IMAGE_NAME} to a ${VOID_DISK_SIZE_MB} MiB (or larger) device"
log "using Balena Etcher or a similar tool."
