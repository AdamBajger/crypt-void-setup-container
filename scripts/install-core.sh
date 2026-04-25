#!/bin/bash
# install-core.sh - Device-agnostic install primitives sourced by entrypoint.sh.
#
# All functions operate on whatever block device path the caller supplies, with
# no awareness of how that device was acquired (loop, virtio-blk, etc.).
# Callers are expected to set `set -euo pipefail`; functions return non-zero on
# failure rather than exiting.

partition_device() {
    local device="$1"

    : "${VOID_EFI_PARTITION_INDEX:=1}"
    : "${VOID_LUKS_PARTITION_INDEX:=2}"

    log "Wiping existing signatures on ${device}..."
    wipefs -a "${device}"

    log "Partitioning ${device} with GPT layout..."
    local efi_part_start=1
    local efi_part_end=$((efi_part_start + VOID_EFI_PARTITION_SIZE_MIB))
    local luks_part_start=${efi_part_end}

    parted --script "${device}" \
        mklabel gpt \
        mkpart void-efi-partition  fat32 "${efi_part_start}MiB"  "${efi_part_end}MiB" \
        mkpart void-luks-partition       "${luks_part_start}MiB" "100%" \
        set "${VOID_EFI_PARTITION_INDEX}" esp on
}

setup_luks() {
    local luks_partition="$1"

    export VOID_LUKS_DEVICE_NAME="${VOID_LUKS_DEVICE_NAME:-void-luks}"
    export VOID_LUKS_MAPPER="/dev/mapper/${VOID_LUKS_DEVICE_NAME}"
    # Back-compat alias for callers that still reference the old name.
    export VOID_LUKS_DEVICE_PATH="${VOID_LUKS_MAPPER}"

    log "Discard-wiping ${luks_partition} to reduce prior-data remanence..."
    blkdiscard -f "${luks_partition}" || log "  (blkdiscard not supported on this platform, skipping)"

    log "Formatting ${luks_partition} as LUKS1 with PBKDF2..."
    echo -n "${LUKS_PASSWORD}" | cryptsetup luksFormat \
        --type luks1 \
        --pbkdf pbkdf2 \
        --batch-mode \
        "${luks_partition}" -

    log "Opening LUKS container as ${VOID_LUKS_DEVICE_NAME}..."
    echo -n "${LUKS_PASSWORD}" | cryptsetup open \
        "${luks_partition}" "${VOID_LUKS_DEVICE_NAME}" -
}

setup_lvm() {
    log "Initialising LVM physical volume on ${VOID_LUKS_MAPPER}..."
    pvcreate "${VOID_LUKS_MAPPER}"

    log "Creating volume group ${VOID_LVM_VG_NAME}..."
    vgcreate "${VOID_LVM_VG_NAME}" "${VOID_LUKS_MAPPER}"

    log "Creating swap logical volume (${VOID_SWAP_SIZE_MIB} MiB)..."
    lvcreate -W n -Zn -L "${VOID_SWAP_SIZE_MIB}M" -n "${VOID_LVM_SWAP_LV_NAME}" "${VOID_LVM_VG_NAME}"

    log "Creating root logical volume (remaining space)..."
    lvcreate -W n -Zn -l 100%FREE -n "${VOID_LVM_ROOT_LV_NAME}" "${VOID_LVM_VG_NAME}"

    # Ensure /dev/<vg>/<lv> nodes exist even if udev is unavailable in container.
    vgchange -ay "${VOID_LVM_VG_NAME}" >/dev/null
    vgmknodes "${VOID_LVM_VG_NAME}" >/dev/null || true
}

mkfs_filesystems() {
    local efi_partition="$1"

    log "Formatting EFI partition as FAT32..."
    mkfs.vfat -F32 -n VOID-EFI "${efi_partition}"

    log "Formatting root logical volume as ext4..."
    mkfs.ext4 -L void-root "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}"

    log "Setting up swap on swap logical volume..."
    mkswap -L void-swap "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_SWAP_LV_NAME}"
}

mount_target() {
    local efi_partition="$1"

    log "Mounting root filesystem at ${VOID_INSTALL_MOUNT}..."
    mkdir -p "${VOID_INSTALL_MOUNT}"
    mount "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}" "${VOID_INSTALL_MOUNT}"

    log "Mounting EFI partition at ${VOID_INSTALL_MOUNT}/boot/efi..."
    mkdir -p "${VOID_INSTALL_MOUNT}/boot/efi"
    mount "${efi_partition}" "${VOID_INSTALL_MOUNT}/boot/efi"
}

install_base_system() {
    log "Installing base packages into ${VOID_INSTALL_MOUNT}..."
    log "  (Downloads from ${VOID_XBPS_REPOSITORY} - may take a while.)"

    mkdir -p "${VOID_INSTALL_MOUNT}/var/db/xbps/keys"
    cp /var/db/xbps/keys/* "${VOID_INSTALL_MOUNT}/var/db/xbps/keys/"

    XBPS_ARCH="${VOID_TARGET_ARCH}" xbps-install \
        -y \
        -S \
        -r "${VOID_INSTALL_MOUNT}" \
        --repository="${VOID_XBPS_REPOSITORY}" \
        base-system \
        grub-x86_64-efi \
        efibootmgr \
        cryptsetup \
        lvm2 \
        dracut

    log "Base package installation complete."
}

copy_chroot_artifacts() {
    log "Copying binaries into chroot..."
    mkdir -p "${VOID_INSTALL_MOUNT}/binaries"
    cp -a /binaries/. "${VOID_INSTALL_MOUNT}/binaries/"

    log "Copying extra package list into chroot..."
    cp /config/extra-packages.txt "${VOID_INSTALL_MOUNT}/tmp/extra-packages.txt"

    log "Copying firstboot artifacts into chroot..."
    cp /setup/firstboot.sh         "${VOID_INSTALL_MOUNT}/tmp/firstboot.sh"
    cp /setup/firstboot-runit-run  "${VOID_INSTALL_MOUNT}/tmp/firstboot-runit-run"
    chmod +x "${VOID_INSTALL_MOUNT}/tmp/firstboot.sh"
    chmod +x "${VOID_INSTALL_MOUNT}/tmp/firstboot-runit-run"

    log "Copying extra customisation script into chroot..."
    cp /setup/void-setup-extras.sh "${VOID_INSTALL_MOUNT}/tmp/void-setup-extras.sh"
    chmod +x "${VOID_INSTALL_MOUNT}/tmp/void-setup-extras.sh"
}

run_minimal_setup() {
    log "Copying minimal setup script into chroot..."
    cp /setup/void-setup-minimal.sh "${VOID_INSTALL_MOUNT}/tmp/void-setup-minimal.sh"
    chmod +x "${VOID_INSTALL_MOUNT}/tmp/void-setup-minimal.sh"

    log "Running minimal system configuration inside xchroot..."
    log "Password variables before xchroot call:"
    log "  ROOT_PASSWORD length: ${#ROOT_PASSWORD}"
    log "  USER_PASSWORD length: ${#USER_PASSWORD}"
    xchroot "${VOID_INSTALL_MOUNT}" /tmp/void-setup-minimal.sh
}

run_extras_setup() {
    log "Running void-setup-extras.sh inside xchroot..."
    xchroot "${VOID_INSTALL_MOUNT}" /tmp/void-setup-extras.sh
}

teardown_target() {
    umount "${VOID_INSTALL_MOUNT}/boot/efi" 2>/dev/null || true
    umount "${VOID_INSTALL_MOUNT}" 2>/dev/null || true
    if [[ -n "${VOID_LVM_VG_NAME:-}" ]]; then
        vgchange -an "${VOID_LVM_VG_NAME}" 2>/dev/null || true
    fi
    if [[ -n "${VOID_LUKS_DEVICE_NAME:-}" ]]; then
        cryptsetup close "${VOID_LUKS_DEVICE_NAME}" 2>/dev/null || true
    fi
}
