#!/bin/bash
# entrypoint.sh — Main orchestration script for the crypt-void-setup-container.
#
# This script runs inside the VoidLinux Docker container and performs the full
# pipeline:
#   1. Parse YAML configuration files.
#   2. Create a loopback disk image in the output directory.
#   3. Partition the image (GPT: EFI + LUKS).
#   4. Set up LUKS1 encryption with PBKDF2 on the second partition.
#   5. Set up LVM (volume group + logical volumes) inside the LUKS container.
#   6. Format all filesystems (FAT32 / ext4 / swap).
#   7. Mount the filesystem tree.
#   8. Bootstrap a minimal VoidLinux installation (void-bootstrap.sh).
#   9. Run void-installation-script.sh inside xchroot to configure the system.

set -euo pipefail

# ---------------------------------------------------------------------------
# Hard-coded names — kept verbose and consistent for maximum readability.
# ---------------------------------------------------------------------------
readonly DISK_CONFIG_FILE="/config/disk.yaml"
readonly SYSTEM_CONFIG_FILE="/config/system.yaml"
readonly OUTPUT_DIR="/output"

readonly VOID_LUKS_DEVICE_NAME="void-luks"
readonly VOID_LUKS_DEVICE_PATH="/dev/mapper/${VOID_LUKS_DEVICE_NAME}"

readonly VOID_LVM_VG_NAME="void-vg"
readonly VOID_LVM_ROOT_LV_NAME="void-root"
readonly VOID_LVM_SWAP_LV_NAME="void-swap"

readonly VOID_INSTALL_MOUNT="/mnt/void-install"

readonly VOID_XBPS_REPOSITORY="https://repo-default.voidlinux.org/current"

# Partition indices within the loop device.
readonly VOID_EFI_PARTITION_INDEX=1
readonly VOID_LUKS_PARTITION_INDEX=2

# Runtime-populated device paths.
VOID_LOOP_DEVICE=""
VOID_EFI_PARTITION=""
VOID_LUKS_PARTITION=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[void-setup] $*"; }
die() { echo "[void-setup] ERROR: $*" >&2; exit 1; }

cleanup_minimal() {
    # Best-effort cleanup: release kernel resources even on failure.
    umount "${VOID_INSTALL_MOUNT}/boot/efi" 2>/dev/null || true
    umount "${VOID_INSTALL_MOUNT}" 2>/dev/null || true
    vgchange -an "${VOID_LVM_VG_NAME}" 2>/dev/null || true
    cryptsetup close "${VOID_LUKS_DEVICE_NAME}" 2>/dev/null || true
    if [[ -n "${VOID_EFI_PARTITION:-}" ]]; then
        losetup -d "${VOID_EFI_PARTITION}" 2>/dev/null || true
    fi
    if [[ -n "${VOID_LUKS_PARTITION:-}" ]]; then
        losetup -d "${VOID_LUKS_PARTITION}" 2>/dev/null || true
    fi
    if [[ -n "${VOID_LOOP_DEVICE:-}" ]]; then
        losetup -d "${VOID_LOOP_DEVICE}" 2>/dev/null || true
    fi
}

trap cleanup_minimal EXIT

ensure_loop_nodes() {
    # Docker containers may not expose all loop device nodes by default.
    [[ -c /dev/loop-control ]] || mknod -m 660 /dev/loop-control c 10 237 || true
    local i
    for i in $(seq 0 63); do
        [[ -b "/dev/loop${i}" ]] || mknod -m 660 "/dev/loop${i}" b 7 "${i}" || true
    done
}

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
[[ -n "${LUKS_PASSWORD:-}" ]] || die "LUKS_PASSWORD is required but not set"
[[ -n "${ROOT_PASSWORD:-}" ]] || die "ROOT_PASSWORD is required but not set"
[[ -n "${USER_PASSWORD:-}" ]] || die "USER_PASSWORD is required but not set"

log "Ensuring loop device nodes are present..."
ensure_loop_nodes

# ---------------------------------------------------------------------------
# Step 1 — Parse YAML configuration.
# ---------------------------------------------------------------------------
log "Reading disk configuration from ${DISK_CONFIG_FILE}..."
VOID_DISK_SIZE_MIB=$(get_yaml_value "${DISK_CONFIG_FILE}" "disk_size_mib")
VOID_EFI_PARTITION_SIZE_MIB=$(get_yaml_value "${DISK_CONFIG_FILE}" "efi_partition_size_mib")
VOID_SWAP_SIZE_MIB=$(get_yaml_value "${DISK_CONFIG_FILE}" "swap_size_mib")

log "Reading system configuration from ${SYSTEM_CONFIG_FILE}..."
VOID_HOSTNAME=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "hostname")
VOID_USERNAME=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "username")
VOID_TIMEZONE=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "timezone")
VOID_LOCALE=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "locale")
VOID_KEYMAP=$(get_yaml_value "${SYSTEM_CONFIG_FILE}" "keymap")

log "  disk_size_mib          = ${VOID_DISK_SIZE_MIB}"
log "  efi_partition_size_mib = ${VOID_EFI_PARTITION_SIZE_MIB}"
log "  swap_size_mib          = ${VOID_SWAP_SIZE_MIB}"
log "  hostname              = ${VOID_HOSTNAME}"
log "  username              = ${VOID_USERNAME}"
log "  timezone              = ${VOID_TIMEZONE}"
log "  locale                = ${VOID_LOCALE}"
log "  keymap                = ${VOID_KEYMAP}"

# ---------------------------------------------------------------------------
# Step 2 — Create the loopback disk image directly in the output directory.
#          Writing to /output from the start avoids a final cp that would
#          require 2× the image size on disk.
# ---------------------------------------------------------------------------
VOID_OUTPUT_IMAGE_NAME="void-linux-encrypted-$(date +%Y%m%d-%H%M%S).img"
VOID_DISK_IMAGE_PATH="${OUTPUT_DIR}/${VOID_OUTPUT_IMAGE_NAME}"

log "Creating ${VOID_DISK_SIZE_MIB} MiB disk image at ${VOID_DISK_IMAGE_PATH}..."
truncate -s "${VOID_DISK_SIZE_MIB}M" "${VOID_DISK_IMAGE_PATH}"

log "Attaching disk image to a loop device..."
VOID_LOOP_DEVICE=$(losetup --find --show --partscan "${VOID_DISK_IMAGE_PATH}")
log "  loop device = ${VOID_LOOP_DEVICE}"

# ---------------------------------------------------------------------------
# Step 3 — Partition the disk image (GPT layout targeting EFI systems).
# ---------------------------------------------------------------------------
log "Partitioning disk image with GPT layout..."

# All start/end positions are in MiB to ensure proper alignment.
VOID_EFI_PART_START=1
VOID_EFI_PART_END=$((VOID_EFI_PART_START + VOID_EFI_PARTITION_SIZE_MIB))
VOID_LUKS_PART_START=${VOID_EFI_PART_END}

parted --script "${VOID_LOOP_DEVICE}" \
    mklabel gpt \
    mkpart void-efi-partition  fat32 "${VOID_EFI_PART_START}MiB"  "${VOID_EFI_PART_END}MiB" \
    mkpart void-luks-partition       "${VOID_LUKS_PART_START}MiB" "100%" \
    set "${VOID_EFI_PARTITION_INDEX}" esp on

# Some container kernels expose partition metadata but do not create /dev/loopXpY
# nodes reliably. Map each partition as its own loop device by byte offset.
SECTOR_SIZE=$(blockdev --getss "${VOID_LOOP_DEVICE}")
EFI_PART_LINE=$(parted -ms "${VOID_LOOP_DEVICE}" unit s print | awk -F: '$1=="1" {print $2":"$4}')
LUKS_PART_LINE=$(parted -ms "${VOID_LOOP_DEVICE}" unit s print | awk -F: '$1=="2" {print $2":"$4}')

[[ -n "${EFI_PART_LINE}" ]] || die "Could not read EFI partition layout from parted output"
[[ -n "${LUKS_PART_LINE}" ]] || die "Could not read LUKS partition layout from parted output"

EFI_START_SECTORS=${EFI_PART_LINE%:*}
EFI_SIZE_SECTORS=${EFI_PART_LINE#*:}
LUKS_START_SECTORS=${LUKS_PART_LINE%:*}
LUKS_SIZE_SECTORS=${LUKS_PART_LINE#*:}

EFI_START_SECTORS=${EFI_START_SECTORS%s}
EFI_SIZE_SECTORS=${EFI_SIZE_SECTORS%s}
LUKS_START_SECTORS=${LUKS_START_SECTORS%s}
LUKS_SIZE_SECTORS=${LUKS_SIZE_SECTORS%s}

VOID_EFI_PARTITION=$(losetup --find --show \
    --offset "$((EFI_START_SECTORS * SECTOR_SIZE))" \
    --sizelimit "$((EFI_SIZE_SECTORS * SECTOR_SIZE))" \
    "${VOID_DISK_IMAGE_PATH}")
VOID_LUKS_PARTITION=$(losetup --find --show \
    --offset "$((LUKS_START_SECTORS * SECTOR_SIZE))" \
    --sizelimit "$((LUKS_SIZE_SECTORS * SECTOR_SIZE))" \
    "${VOID_DISK_IMAGE_PATH}")

log "  ${VOID_EFI_PARTITION}  — EFI System Partition (FAT32)"
log "  ${VOID_LUKS_PARTITION} — LUKS1 encrypted partition (contains LVM)"

# ---------------------------------------------------------------------------
# Step 4 — Set up LUKS1 encryption with PBKDF2 on the LUKS partition.
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

log "Creating swap logical volume (${VOID_SWAP_SIZE_MIB} MiB)..."
lvcreate -W n -Zn -L "${VOID_SWAP_SIZE_MIB}M" -n "${VOID_LVM_SWAP_LV_NAME}" "${VOID_LVM_VG_NAME}"

log "Creating root logical volume (remaining space)..."
lvcreate -W n -Zn -l 100%FREE -n "${VOID_LVM_ROOT_LV_NAME}" "${VOID_LVM_VG_NAME}"

# Ensure /dev/<vg>/<lv> nodes exist even if udev is unavailable in container.
vgchange -ay "${VOID_LVM_VG_NAME}" >/dev/null
vgmknodes "${VOID_LVM_VG_NAME}" >/dev/null || true

# ---------------------------------------------------------------------------
# Step 6 — Format all filesystems.
# ---------------------------------------------------------------------------
log "Formatting EFI partition as FAT32..."
mkfs.vfat -F32 -n VOID-EFI "${VOID_EFI_PARTITION}"

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

log "Mounting EFI partition at ${VOID_INSTALL_MOUNT}/boot/efi..."
mkdir -p "${VOID_INSTALL_MOUNT}/boot/efi"
mount "${VOID_EFI_PARTITION}" "${VOID_INSTALL_MOUNT}/boot/efi"

# ---------------------------------------------------------------------------
# Step 8 — Bootstrap a minimal VoidLinux installation.
# ---------------------------------------------------------------------------
log "Bootstrapping VoidLinux base system (void-bootstrap.sh)..."
export VOID_INSTALL_MOUNT VOID_XBPS_REPOSITORY
bash /setup/void-bootstrap.sh

# ---------------------------------------------------------------------------
# Step 9 — Configure the system inside xchroot.
# ---------------------------------------------------------------------------
log "Copying installation scripts into chroot..."
cp /setup/void-installation-script.sh "${VOID_INSTALL_MOUNT}/tmp/void-installation-script.sh"
cp /setup/void-setup-minimal.sh       "${VOID_INSTALL_MOUNT}/tmp/void-setup-minimal.sh"
cp /setup/void-setup-extras.sh        "${VOID_INSTALL_MOUNT}/tmp/void-setup-extras.sh"
chmod +x \
    "${VOID_INSTALL_MOUNT}/tmp/void-installation-script.sh" \
    "${VOID_INSTALL_MOUNT}/tmp/void-setup-minimal.sh" \
    "${VOID_INSTALL_MOUNT}/tmp/void-setup-extras.sh"

log "Running void-installation-script.sh inside xchroot..."
# All VOID_* and password variables are exported so that the installation
# scripts can read them from their environment without any additional argument
# passing.
export VOID_HOSTNAME VOID_USERNAME VOID_TIMEZONE VOID_LOCALE VOID_KEYMAP
export VOID_EFI_PARTITION VOID_LUKS_PARTITION
export VOID_LUKS_DEVICE_NAME VOID_LVM_VG_NAME
export VOID_LVM_ROOT_LV_NAME VOID_LVM_SWAP_LV_NAME
export ROOT_PASSWORD USER_PASSWORD LUKS_PASSWORD

xchroot "${VOID_INSTALL_MOUNT}" /tmp/void-installation-script.sh

log "Done.  Flash ${VOID_OUTPUT_IMAGE_NAME} to a ${VOID_DISK_SIZE_MIB} MiB (or larger) device"
log "using Balena Etcher or: sudo dd if=output/${VOID_OUTPUT_IMAGE_NAME} of=/dev/sdX bs=4M status=progress"
